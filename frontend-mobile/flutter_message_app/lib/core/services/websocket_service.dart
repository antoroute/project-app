import 'dart:async';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/models/message.dart';
import 'package:provider/provider.dart';

enum SocketStatus { disconnected, connecting, connected, error }

class WebSocketService {
  WebSocketService._internal();
  static final WebSocketService instance = WebSocketService._internal();

  IO.Socket? _socket;
  SocketStatus _status = SocketStatus.disconnected;
  final StreamController<SocketStatus> _statusController = StreamController.broadcast();
  
  // Gestion des abonnements persistants
  final Set<String> _subscribedConversations = <String>{};
  final Set<String> _pendingSubscriptions = <String>{};
  final Set<String> _subscribedGroups = <String>{};
  
  // Métriques de performance
  int _messagesReceived = 0;
  int _eventsReceived = 0;
  DateTime? _lastActivity;

  SocketStatus get status => _status;
  Stream<SocketStatus> get statusStream => _statusController.stream;
  
  // Getters pour les métriques
  int get messagesReceived => _messagesReceived;
  int get eventsReceived => _eventsReceived;
  DateTime? get lastActivity => _lastActivity;
  Set<String> get subscribedConversations => Set.from(_subscribedConversations);
  Set<String> get subscribedGroups => Set.from(_subscribedGroups);

  /// Callbacks à brancher depuis vos providers
  void Function(Message message)? onNewMessage; // legacy
  void Function(Map<String, dynamic> payloadV2)? onNewMessageV2; // v2 payload
  void Function(String userId, bool online, int count)? onPresenceUpdate;
  void Function(String userId, bool online, int count, String conversationId)? onPresenceConversation;
  void Function(String convId, String userId, String at)? onConvRead;
  void Function(String conversationId, String userId)? onUserAdded;
  VoidCallback? onNotificationNew;
  VoidCallback? onConversationJoined;
  Function(String groupId, String userId, String approverId)? onGroupJoined;
  // Nouveaux callbacks pour les indicateurs de frappe
  void Function(String convId, String userId)? onTypingStart;
  void Function(String convId, String userId)? onTypingStop;
  // Nouveaux callbacks pour les groupes et conversations
  void Function(String groupId, String creatorId)? onGroupCreated;
  void Function(String convId, String groupId, String creatorId)? onConversationCreated;
  void Function(String groupId, String userId, String approverId)? onGroupMemberJoined;

  /// Établit la connexion WS
  Future<void> connect(BuildContext context) async {
    print('🔌 [WebSocket] Starting connection process...');
    if (_status == SocketStatus.connected || _status == SocketStatus.connecting) {
      print('🔌 [WebSocket] Already connected or connecting, skipping');
      return;
    }
    _updateStatus(SocketStatus.connecting);
    print('🔌 [WebSocket] Status updated to connecting');

    final auth = Provider.of<AuthProvider>(context, listen: false);
    print('🔌 [WebSocket] Getting auth provider...');
    final valid = await auth.ensureTokenValid();
    if (!valid) {
      print('🔌 [WebSocket] Token validation failed');
      _handleError('Token invalide ou rafraîchissement échoué.');
      return;
    }
    final token = auth.token!;
    print('🔌 [WebSocket] Token validated, disposing old socket...');
    _disposeSocket();

    try {
      print('🔌 [WebSocket] Creating new socket...');
      _socket = IO.io(
        'https://api.kavalek.fr',
        IO.OptionBuilder()
            .setPath('/socket')
            .setTransports(['websocket'])
            .setAuth({'token': token})
            .setTimeout(10000)
            .setReconnectionDelay(3000)
            .setReconnectionAttempts(5)
            .build(),
      );
      print('🔌 [WebSocket] Socket created, registering listeners...');
      _registerListeners(context);
      print('🔌 [WebSocket] Listeners registered, attempting connection...');
      _socket!.connect();
      print('🔌 [WebSocket] Connection attempt initiated');
    } catch (e) {
      print('🔌 [WebSocket] Connection failed with error: $e');
      _handleError("Erreur d'initialisation du WebSocket: $e");
    }
  }

  void _registerListeners(BuildContext context) {
    if (_socket == null) return;

    _socket!
      ..onConnect((_) {
        print('🔌 [WebSocket] ✅ CONNECTED!');
        _log('WebSocket connecté', level: 'info');
        _updateStatus(SocketStatus.connected);
        
        // Réabonner automatiquement aux conversations précédemment souscrites
        _resubscribeToConversations();
      })
      ..onDisconnect((_) {
        print('🔌 [WebSocket] ❌ DISCONNECTED!');
        _log('WebSocket déconnecté', level: 'warn');
        _updateStatus(SocketStatus.disconnected);
        Future.delayed(const Duration(seconds: 3), () {
          // Vérifier que le contexte est encore valide avant de reconnecter
          if (context.mounted) {
            print('🔌 [WebSocket] Attempting reconnection...');
            connect(context);
          }
        });
      })
      // v2 message:new : payload v2 complet (Map<String,dynamic>)
      ..on('message:new', (data) {
        _log('📨 Événement message:new reçu: ${data.runtimeType}', level: 'info');
        _updateActivityMetrics();
        _messagesReceived++;
        
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          _log('📨 Données message:new parsées: ${map.keys}', level: 'info');
          // Deliver raw v2 payload to providers
          onNewMessageV2?.call(map);
        } else {
          _log('❌ Données message:new invalides: ${data.runtimeType}', level: 'error');
        }
      })
      ..on('presence:update', (data) {
        _log('👥 Événement presence:update reçu: ${data.runtimeType}', level: 'info');
        _updateActivityMetrics();
        
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final uid = m['userId'] as String;
          final online = m['online'] as bool;
          final count = (m['count'] as num?)?.toInt() ?? 0;
          _log('👥 Présence mise à jour: $uid = $online (count: $count)', level: 'info');
          _log('👥 [WebSocket] onPresenceUpdate callback: ${onPresenceUpdate != null ? 'defined' : 'null'}', level: 'info');
          if (onPresenceUpdate != null) {
            _log('👥 [WebSocket] Calling onPresenceUpdate for $uid', level: 'info');
            onPresenceUpdate!(uid, online, count);
          } else {
            _log('👥 [WebSocket] onPresenceUpdate callback is null - skipping', level: 'warn');
          }
        } else {
          _log('❌ Données presence:update invalides: ${data.runtimeType}', level: 'error');
        }
      })
      ..on('presence:conversation', (data) {
        _log('💬 Événement presence:conversation reçu: ${data.runtimeType}', level: 'info');
        _updateActivityMetrics();
        
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final uid = m['userId'] as String;
          final online = m['online'] as bool;
          final count = (m['count'] as num?)?.toInt() ?? 0;
          final conversationId = m['conversationId'] as String;
          _log('💬 Présence conversation mise à jour: $uid = $online (count: $count) dans $conversationId', level: 'info');
          _log('💬 [WebSocket] onPresenceConversation callback: ${onPresenceConversation != null ? 'defined' : 'null'}', level: 'info');
          onPresenceConversation?.call(uid, online, count, conversationId);
        } else {
          _log('❌ Données presence:conversation invalides: ${data.runtimeType}', level: 'error');
        }
      })
      ..on('conv:read', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final convId = m['convId'] as String;
          final userId = m['userId'] as String;
          final at = m['at'] as String;
          onConvRead?.call(convId, userId, at);
        }
      })
      ..on('conversation:user_added', (data) {
        final Map<String, dynamic> json = data as Map<String, dynamic>;
        onUserAdded?.call(
          json['conversationId'] as String,
          json['userId'] as String,
        );
      })
      ..on('notification:new', (_) => onNotificationNew?.call())
      ..on('conversation:joined', (_) => onConversationJoined?.call())
      ..on('group:joined', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final groupId = m['groupId'] as String;
          final userId = m['userId'] as String;
          final approverId = m['approverId'] as String;
          onGroupJoined?.call(groupId, userId, approverId);
        }
      })
      ..on('group:user_added', (data) {
        final Map<String, dynamic> json = data as Map<String, dynamic>;
        _log(
          'Nouvel utilisateur ajouté au groupe '
          '${json['groupId']} : ${json['userId']}',
          level: 'info',
        );
      })
      // Nouveaux événements pour les indicateurs de frappe
      ..on('typing:start', (data) {
        _log('✏️ Événement typing:start reçu: ${data.runtimeType}', level: 'info');
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final convId = m['convId'] as String;
          final userId = m['userId'] as String;
          _log('✏️ Frappe démarrée: $userId dans $convId', level: 'info');
          onTypingStart?.call(convId, userId);
        } else {
          _log('❌ Données typing:start invalides: ${data.runtimeType}', level: 'error');
        }
      })
      ..on('typing:stop', (data) {
        _log('✏️ Événement typing:stop reçu: ${data.runtimeType}', level: 'info');
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final convId = m['convId'] as String;
          final userId = m['userId'] as String;
          _log('✏️ Frappe arrêtée: $userId dans $convId', level: 'info');
          onTypingStop?.call(convId, userId);
        } else {
          _log('❌ Données typing:stop invalides: ${data.runtimeType}', level: 'error');
        }
      })
      ..on('group:created', (data) {
        _log('🏗️ Événement group:created reçu: ${data.runtimeType}', level: 'info');
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final groupId = m['groupId'] as String;
          final creatorId = m['creatorId'] as String;
          _log('🏗️ Nouveau groupe créé: $groupId par $creatorId', level: 'info');
          onGroupCreated?.call(groupId, creatorId);
        } else {
          _log('❌ Données group:created invalides: ${data.runtimeType}', level: 'error');
        }
      })
      ..on('conversation:created', (data) {
        _log('💬 Événement conversation:created reçu: ${data.runtimeType}', level: 'info');
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final convId = m['convId'] as String;
          final groupId = m['groupId'] as String;
          final creatorId = m['creatorId'] as String;
          _log('💬 Nouvelle conversation créée: $convId dans $groupId par $creatorId', level: 'info');
          onConversationCreated?.call(convId, groupId, creatorId);
        } else {
          _log('❌ Données conversation:created invalides: ${data.runtimeType}', level: 'error');
        }
      })
      ..on('group:member_joined', (data) {
        _log('👥 Événement group:member_joined reçu: ${data.runtimeType}', level: 'info');
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final groupId = m['groupId'] as String;
          final userId = m['userId'] as String;
          final approverId = m['approverId'] as String;
          _log('👥 Nouveau membre dans le groupe: $userId dans $groupId par $approverId', level: 'info');
          _log('👥 [WebSocket] onGroupMemberJoined callback: ${onGroupMemberJoined != null ? 'defined' : 'null'}', level: 'info');
          onGroupMemberJoined?.call(groupId, userId, approverId);
        } else {
          _log('❌ Données group:member_joined invalides: ${data.runtimeType}', level: 'error');
        }
      })
      ..on('group:joined', (data) {
        _log('👥 Événement group:joined reçu: ${data.runtimeType}', level: 'info');
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final groupId = m['groupId'] as String;
          final userId = m['userId'] as String;
          final approverId = m['approverId'] as String;
          _log('👥 Utilisateur a rejoint le groupe: $userId dans $groupId par $approverId', level: 'info');
          _log('👥 [WebSocket] onGroupJoined callback: ${onGroupJoined != null ? 'defined' : 'null'}', level: 'info');
          onGroupJoined?.call(groupId, userId, approverId);
        } else {
          _log('❌ Données group:joined invalides: ${data.runtimeType}', level: 'error');
        }
      })
      ..onError((err) {
        print('🔌 [WebSocket] ❌ ERROR: $err');
        _handleError('Erreur WebSocket: $err');
      })
      ..on('connect_error', (err) {
        print('🔌 [WebSocket] ❌ CONNECT ERROR: $err');
        _handleError('Erreur de connexion: $err');
      });
  }

  void subscribeConversation(String conversationId) {
    // Ajouter à la liste des abonnements persistants
    _subscribedConversations.add(conversationId);
    
    if (_status != SocketStatus.connected || _socket == null) {
      // Si pas connecté, ajouter aux abonnements en attente
      _pendingSubscriptions.add(conversationId);
      _log('⏳ Abonnement en attente pour la conversation : $conversationId', level: 'info');
      return;
    }
    _log('📡 Socket status: connected, emitting conv:subscribe for $conversationId', level: 'info');
    
    _log('Demande d\'abonnement a la conversation : $conversationId', level: 'info');
    _socket!.emitWithAck(
      'conv:subscribe',
      {'convId': conversationId},
      ack: (resp) {
        final ok = resp is Map && resp['success'] == true;
        _log(ok
            ? 'Abonnement reussi a $conversationId'
            : 'Echec abonnement a $conversationId (ack: $resp)',
          level: ok ? 'info' : 'warn'
        );
      },
    );
  }

  void unsubscribeConversation(String conversationId, {String? userId}) {
    // Retirer de la liste des abonnements persistants
    _subscribedConversations.remove(conversationId);
    _pendingSubscriptions.remove(conversationId);
    
    if (_status != SocketStatus.connected || _socket == null) return;
    _log('Desabonnement de la conversation : $conversationId', level: 'info');
    _socket!.emit('conv:unsubscribe', {'convId': conversationId});
    
    // CORRECTION: Émettre un événement de présence hors ligne pour cette conversation
    if (onPresenceConversation != null && userId != null) {
      _log('👥 [WebSocket] Emitting offline presence for conversation $conversationId', level: 'info');
      onPresenceConversation!(userId, false, 0, conversationId);
    }
  }
  
  /// Émet un événement de début de frappe
  void emitTypingStart(String conversationId) {
    if (_status != SocketStatus.connected || _socket == null) {
      _log('❌ Impossible d\'émettre typing:start: socket non connecté', level: 'warn');
      return;
    }
    _log('✏️ Émission typing:start pour $conversationId', level: 'info');
    _socket!.emit('typing:start', {'convId': conversationId});
  }
  
  /// Émet un événement de fin de frappe
  void emitTypingStop(String conversationId) {
    if (_status != SocketStatus.connected || _socket == null) {
      _log('❌ Impossible d\'émettre typing:stop: socket non connecté', level: 'warn');
      return;
    }
    _log('✏️ Émission typing:stop pour $conversationId', level: 'info');
    _socket!.emit('typing:stop', {'convId': conversationId});
  }
  
  /// Réabonne automatiquement aux conversations lors de la reconnexion
  void _resubscribeToConversations() {
    for (final convId in _subscribedConversations) {
      _log('Reabonnement automatique a la conversation : $convId', level: 'info');
      _socket!.emitWithAck(
        'conv:subscribe',
        {'convId': convId},
        ack: (resp) {
          final ok = resp is Map && resp['success'] == true;
          _log(ok
              ? 'Reabonnement reussi a $convId'
              : 'Echec reabonnement a $convId (ack: $resp)',
            level: ok ? 'info' : 'warn'
          );
        },
      );
    }
    
    // Traiter les abonnements en attente
    for (final convId in _pendingSubscriptions) {
      subscribeConversation(convId);
    }
    _pendingSubscriptions.clear();
  }
  
  /// Gestion intelligente des abonnements avec métriques
  void _updateActivityMetrics() {
    _lastActivity = DateTime.now();
    _eventsReceived++;
  }
  
  /// Nettoie les abonnements obsolètes
  void cleanupSubscriptions() {
    final now = DateTime.now();
    if (_lastActivity != null && now.difference(_lastActivity!).inMinutes > 30) {
      _log('🧹 Nettoyage des abonnements obsolètes', level: 'info');
      _subscribedConversations.clear();
      _pendingSubscriptions.clear();
    }
  }
  
  /// Obtient les statistiques de performance
  Map<String, dynamic> getPerformanceStats() {
    return {
      'messagesReceived': _messagesReceived,
      'eventsReceived': _eventsReceived,
      'subscribedConversations': _subscribedConversations.length,
      'subscribedGroups': _subscribedGroups.length,
      'lastActivity': _lastActivity?.toIso8601String(),
      'status': _status.name,
    };
  }

  void disconnect() {
    _disposeSocket();
    _updateStatus(SocketStatus.disconnected);
  }

  void _disposeSocket() {
    _socket?.clearListeners();
    _socket?.disconnect();
    _socket = null;
  }

  void _updateStatus(SocketStatus newStatus) {
    _status = newStatus;
    _statusController.add(_status);
  }

  void _handleError(String message) {
    _log(message, level: 'error');
    _updateStatus(SocketStatus.error);
  }

  void _log(String message, {String level = 'info'}) {
    print('[WebSocketService][$level] $message');
  }
}
