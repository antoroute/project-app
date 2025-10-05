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

  SocketStatus get status => _status;
  Stream<SocketStatus> get statusStream => _statusController.stream;

  /// Callbacks à brancher depuis vos providers
  void Function(Message message)? onNewMessage; // legacy
  void Function(Map<String, dynamic> payloadV2)? onNewMessageV2; // v2 payload
  void Function(String userId, bool online, int count)? onPresenceUpdate;
  void Function(String convId, String userId, String at)? onConvRead;
  void Function(String conversationId, String userId)? onUserAdded;
  VoidCallback? onNotificationNew;
  VoidCallback? onConversationJoined;
  VoidCallback? onGroupJoined;
  // Nouveaux callbacks pour les indicateurs de frappe
  void Function(String convId, String userId)? onTypingStart;
  void Function(String convId, String userId)? onTypingStop;
  // Nouveaux callbacks pour les groupes et conversations
  void Function(String groupId, String creatorId)? onGroupCreated;
  void Function(String convId, String groupId, String creatorId)? onConversationCreated;

  /// Établit la connexion WS
  Future<void> connect(BuildContext context) async {
    if (_status == SocketStatus.connected || _status == SocketStatus.connecting) return;
    _updateStatus(SocketStatus.connecting);

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final valid = await auth.ensureTokenValid();
    if (!valid) {
      _handleError('Token invalide ou rafraîchissement échoué.');
      return;
    }
    final token = auth.token!;
    _disposeSocket();

    try {
      _socket = IO.io(
        'https://api.kavalek.fr',
        IO.OptionBuilder()
            .setPath('/socket')
            .setTransports(['websocket'])
            .setAuth({'token': token})
            .build(),
      );
      _registerListeners(context);
      _socket!.connect();
    } catch (e) {
      _handleError("Erreur d'initialisation du WebSocket: $e");
    }
  }

  void _registerListeners(BuildContext context) {
    if (_socket == null) return;

    _socket!
      ..onConnect((_) {
        _log('WebSocket connecté', level: 'info');
        _updateStatus(SocketStatus.connected);
        
        // Réabonner automatiquement aux conversations précédemment souscrites
        _resubscribeToConversations();
      })
      ..onDisconnect((_) {
        _log('WebSocket déconnecté', level: 'warn');
        _updateStatus(SocketStatus.disconnected);
        Future.delayed(const Duration(seconds: 3), () => connect(context));
      })
      // v2 message:new : payload v2 complet (Map<String,dynamic>)
      ..on('message:new', (data) {
        _log('📨 Événement message:new reçu: ${data.runtimeType}', level: 'info');
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
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final uid = m['userId'] as String;
          final online = m['online'] as bool;
          final count = (m['count'] as num?)?.toInt() ?? 0;
          _log('👥 Présence mise à jour: $uid = $online (count: $count)', level: 'info');
          onPresenceUpdate?.call(uid, online, count);
        } else {
          _log('❌ Données presence:update invalides: ${data.runtimeType}', level: 'error');
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
      ..on('group:joined', (_) => onGroupJoined?.call())
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
      ..onError((err) => _handleError('Erreur WebSocket: $err'))
      ..on('connect_error', (err) => _handleError('Erreur de connexion: $err'));
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

  void unsubscribeConversation(String conversationId) {
    // Retirer de la liste des abonnements persistants
    _subscribedConversations.remove(conversationId);
    _pendingSubscriptions.remove(conversationId);
    
    if (_status != SocketStatus.connected || _socket == null) return;
    _log('Desabonnement de la conversation : $conversationId', level: 'info');
    _socket!.emit('conv:unsubscribe', {'convId': conversationId});
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
