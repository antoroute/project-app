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
    if (_status == SocketStatus.connected || _status == SocketStatus.connecting) {
      return;
    }
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
            .setTimeout(10000)
            .setReconnectionDelay(3000)
            .setReconnectionAttempts(5)
            .setReconnectionDelayMax(10000) // Délai max entre tentatives
            .setRandomizationFactor(0.5) // Randomisation pour éviter les reconnexions simultanées
            .enableAutoConnect() // Reconnexion automatique activée
            .enableForceNew() // Forcer une nouvelle connexion si nécessaire
            // Note: setCompression n'est pas disponible dans socket_io_client 2.0.0
            // La compression peut être gérée côté serveur si nécessaire
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
        _updateStatus(SocketStatus.connected);
        // Réabonner automatiquement aux conversations précédemment souscrites
        _resubscribeToConversations();
      })
      ..onDisconnect((_) {
        _updateStatus(SocketStatus.disconnected);
        debugPrint('🔌 [WebSocket] Disconnected, will attempt reconnection in 3s');
        // Reconnexion automatique seulement si l'app est toujours montée
        Future.delayed(const Duration(seconds: 3), () {
          if (context.mounted) {
            debugPrint('🔄 [WebSocket] Attempting reconnection...');
            connect(context);
          }
        });
      })
      ..onReconnect((attempt) {
        debugPrint('🔄 [WebSocket] Reconnecting (attempt $attempt)...');
        _updateStatus(SocketStatus.connecting);
      })
      ..onReconnectAttempt((attempt) {
        debugPrint('🔄 [WebSocket] Reconnection attempt $attempt');
      })
      ..onReconnectError((error) {
        debugPrint('❌ [WebSocket] Reconnection error: $error');
        _handleError('Erreur de reconnexion: $error');
      })
      ..onReconnectFailed((error) {
        debugPrint('❌ [WebSocket] Reconnection failed after all attempts: $error');
        _updateStatus(SocketStatus.error);
      })
      // v2 message:new : payload v2 complet (Map<String,dynamic>)
      ..on('message:new', (data) {
        _updateActivityMetrics();
        _messagesReceived++;
        
        debugPrint('📨 [WebSocket] Message reçu via WebSocket (total: $_messagesReceived)');
        
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          final convId = map['convId'] as String?;
          final messageId = map['messageId'] as String?;
          debugPrint('📨 [WebSocket] Message détails: convId=$convId, messageId=$messageId');
          debugPrint('📨 [WebSocket] Callback onNewMessageV2: ${onNewMessageV2 != null ? "branché" : "NON BRANCHÉ"}');
          
          if (onNewMessageV2 != null) {
            onNewMessageV2!(map);
            debugPrint('📨 [WebSocket] Callback onNewMessageV2 appelé');
          } else {
            debugPrint('⚠️ [WebSocket] Callback onNewMessageV2 non branché !');
          }
        } else {
          debugPrint('⚠️ [WebSocket] Message reçu mais format invalide: ${data.runtimeType}');
        }
      })
      ..on('presence:update', (data) {
        _updateActivityMetrics();
        
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final uid = m['userId'] as String;
          final online = m['online'] as bool;
          final count = (m['count'] as num?)?.toInt() ?? 0;
          onPresenceUpdate?.call(uid, online, count);
        }
      })
      ..on('presence:conversation', (data) {
        _updateActivityMetrics();
        
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final uid = m['userId'] as String;
          final online = m['online'] as bool;
          final count = (m['count'] as num?)?.toInt() ?? 0;
          final conversationId = m['conversationId'] as String;
          onPresenceConversation?.call(uid, online, count, conversationId);
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
        // Log silencieux pour les événements de groupe
      })
      // Nouveaux événements pour les indicateurs de frappe
      ..on('typing:start', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final convId = m['convId'] as String;
          final userId = m['userId'] as String;
          onTypingStart?.call(convId, userId);
        }
      })
      ..on('typing:stop', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final convId = m['convId'] as String;
          final userId = m['userId'] as String;
          onTypingStop?.call(convId, userId);
        }
      })
      ..on('group:created', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final groupId = m['groupId'] as String;
          final creatorId = m['creatorId'] as String;
          onGroupCreated?.call(groupId, creatorId);
        }
      })
      ..on('conversation:created', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final convId = m['convId'] as String;
          final groupId = m['groupId'] as String;
          final creatorId = m['creatorId'] as String;
          onConversationCreated?.call(convId, groupId, creatorId);
        }
      })
      ..on('group:member_joined', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final groupId = m['groupId'] as String;
          final userId = m['userId'] as String;
          final approverId = m['approverId'] as String;
          onGroupMemberJoined?.call(groupId, userId, approverId);
        }
      })
      ..on('group:joined', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final groupId = m['groupId'] as String;
          final userId = m['userId'] as String;
          final approverId = m['approverId'] as String;
          onGroupJoined?.call(groupId, userId, approverId);
        }
      })
      ..onError((err) {
        _handleError('Erreur WebSocket: $err');
      })
      ..on('connect_error', (err) {
        _handleError('Erreur de connexion: $err');
      });
  }

  void subscribeConversation(String conversationId) {
    // Ajouter à la liste des abonnements persistants
    _subscribedConversations.add(conversationId);
    
    if (_status != SocketStatus.connected || _socket == null) {
      // Si pas connecté, ajouter aux abonnements en attente
      _pendingSubscriptions.add(conversationId);
      return;
    }
    _socket!.emitWithAck(
      'conv:subscribe',
      {'convId': conversationId},
      ack: (resp) {
        // Log silencieux pour les abonnements
      },
    );
  }

  void unsubscribeConversation(String conversationId, {String? userId}) {
    // Retirer de la liste des abonnements persistants
    _subscribedConversations.remove(conversationId);
    _pendingSubscriptions.remove(conversationId);
    
    if (_status != SocketStatus.connected || _socket == null) return;
    _socket!.emit('conv:unsubscribe', {'convId': conversationId});
    
    // CORRECTION: Émettre un événement de présence hors ligne pour cette conversation
    if (onPresenceConversation != null && userId != null) {
      onPresenceConversation!(userId, false, 0, conversationId);
    }
  }
  
  /// Émet un événement de début de frappe
  void emitTypingStart(String conversationId) {
    if (_status != SocketStatus.connected || _socket == null) {
      return;
    }
    _socket!.emit('typing:start', {'convId': conversationId});
  }
  
  /// Émet un événement de fin de frappe
  void emitTypingStop(String conversationId) {
    if (_status != SocketStatus.connected || _socket == null) {
      return;
    }
    _socket!.emit('typing:stop', {'convId': conversationId});
  }
  
  /// Réabonne automatiquement aux conversations lors de la reconnexion
  void _resubscribeToConversations() {
    for (final convId in _subscribedConversations) {
      _socket!.emitWithAck(
        'conv:subscribe',
        {'convId': convId},
        ack: (resp) {
          // Log silencieux pour les réabonnements
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
    _updateStatus(SocketStatus.error);
  }

}
