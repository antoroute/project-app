import 'dart:async';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/models/message.dart';
import 'package:flutter_message_app/core/services/network_monitor_service.dart';
import 'package:flutter_message_app/config/constants.dart';
import 'package:provider/provider.dart';

enum SocketStatus { disconnected, connecting, connected, error }

class WebSocketService {
  WebSocketService._internal();
  static final WebSocketService instance = WebSocketService._internal();

  IO.Socket? _socket;
  SocketStatus _status = SocketStatus.disconnected;
  final StreamController<SocketStatus> _statusController =
      StreamController.broadcast();

  // ✅ NOUVEAU: Référence à AuthProvider pour reconnexion indépendante du context
  AuthProvider? _authProvider;

  // ✅ NOUVEAU: Flag pour contrôler la reconnexion
  bool _shouldReconnect = true;

  // ✅ NOUVEAU: Subscription au NetworkMonitorService
  StreamSubscription<bool>? _networkSubscription;

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
  void Function(String userId, bool online, int count, String conversationId)?
  onPresenceConversation;

  /// ✅ NOUVEAU: Callback pour les événements de présence batch
  void Function(String conversationId, List<Map<String, dynamic>> presences)?
  onPresenceConversationBatch;
  void Function(String convId, String userId, String at)? onConvRead;
  void Function(String conversationId, String userId)? onUserAdded;
  void Function(String deviceId, List<String> groupIds)? onDeviceRevoked;
  void Function(String groupId, String deviceId)? onDeviceKeyDirectoryChanged;
  VoidCallback? onNotificationNew;
  VoidCallback? onConversationJoined;
  // SÉCURITÉ: Les paramètres peuvent être null si c'est un ping minimal
  void Function(String? groupId, String? userId, String? approverId)?
  onGroupJoined;
  // Nouveaux callbacks pour les indicateurs de frappe
  void Function(String convId, String userId)? onTypingStart;
  void Function(String convId, String userId)? onTypingStop;
  // Nouveaux callbacks pour les groupes et conversations
  // SÉCURITÉ: Les paramètres peuvent être null si c'est un ping minimal
  void Function(String? groupId, String? creatorId)? onGroupCreated;
  void Function(String? convId, String? groupId, String? creatorId)?
  onConversationCreated;
  void Function(String? groupId, String? userId, String? approverId)?
  onGroupMemberJoined;

  /// Établit la connexion WS
  Future<void> connect(BuildContext context) async {
    // ✅ NOUVEAU: Sauvegarder la référence à AuthProvider
    _authProvider = Provider.of<AuthProvider>(context, listen: false);
    if (!_authProvider!.canUseMessaging) {
      debugPrint(
        '🔒 [WebSocket] Connexion bloquée: appareil du compte non actif',
      );
      disconnect();
      return;
    }
    _shouldReconnect = true;

    // ✅ NOUVEAU: Configurer l'écoute du réseau si pas déjà fait
    _setupNetworkListener();

    await _connectInternal();
  }

  /// ✅ NOUVEAU: Connexion interne indépendante du context
  Future<void> _connectInternal() async {
    if (_status == SocketStatus.connected ||
        _status == SocketStatus.connecting) {
      return;
    }

    if (_authProvider == null) {
      debugPrint(
        '⚠️ [WebSocket] AuthProvider non disponible pour la connexion',
      );
      return;
    }
    if (!_authProvider!.canUseMessaging) {
      debugPrint(
        '🔒 [WebSocket] Reconnexion bloquée: appareil du compte non actif',
      );
      disconnect();
      return;
    }

    _updateStatus(SocketStatus.connecting);

    final valid = await _authProvider!.ensureTokenValid();
    if (!valid) {
      _handleError('Token invalide ou rafraîchissement échoué.');
      return;
    }
    final socketAuth = await _authProvider!.getMessagingSocketAuth();
    _disposeSocket();

    try {
      _socket = IO.io(
        'https://api.kavalek.fr',
        IO.OptionBuilder()
            .setPath('/socket')
            .setTransports(['websocket'])
            .setAuth(socketAuth)
            .setExtraHeaders({'X-App-Secret': appSecret})
            .setTimeout(10000)
            .setReconnectionDelay(3000)
            .setReconnectionAttempts(5)
            .setReconnectionDelayMax(10000) // Délai max entre tentatives
            .setRandomizationFactor(
              0.5,
            ) // Randomisation pour éviter les reconnexions simultanées
            .enableAutoConnect() // Reconnexion automatique activée
            .enableForceNew() // Forcer une nouvelle connexion si nécessaire
            // Note: setCompression n'est pas disponible dans socket_io_client 2.0.0
            // La compression peut être gérée côté serveur si nécessaire
            .build(),
      );
      _registerListeners();
      _socket!.connect();
    } catch (e) {
      _handleError("Erreur d'initialisation du WebSocket: $e");
    }
  }

  /// ✅ NOUVEAU: Configure l'écoute du NetworkMonitorService
  void _setupNetworkListener() {
    if (_networkSubscription != null) {
      return; // Déjà configuré
    }

    _networkSubscription = NetworkMonitorService().networkStatusStream.listen((
      isConnected,
    ) {
      if (isConnected &&
          _status == SocketStatus.disconnected &&
          _shouldReconnect) {
        debugPrint(
          '🌐 [WebSocket] Réseau disponible, tentative de reconnexion...',
        );
        _attemptReconnection();
      } else if (!isConnected) {
        debugPrint('🌐 [WebSocket] Réseau indisponible');
      }
    });

    debugPrint('🌐 [WebSocket] NetworkMonitorService listener configuré');
  }

  /// ✅ NOUVEAU: Tente la reconnexion de manière indépendante
  Future<void> _attemptReconnection() async {
    if (!_shouldReconnect) {
      debugPrint('⚠️ [WebSocket] Reconnexion désactivée');
      return;
    }

    if (_status == SocketStatus.connected ||
        _status == SocketStatus.connecting) {
      return;
    }

    debugPrint('🔄 [WebSocket] Tentative de reconnexion...');
    await _connectInternal();
  }

  void _registerListeners() {
    if (_socket == null) return;

    _socket!
      ..onConnect((_) {
        _updateStatus(SocketStatus.connected);
        debugPrint('✅ [WebSocket] Connected successfully');
        // Réabonner automatiquement aux conversations précédemment souscrites
        _resubscribeToConversations();
      })
      ..onDisconnect((_) {
        _updateStatus(SocketStatus.disconnected);
        debugPrint('🔌 [WebSocket] Disconnected');

        // ✅ CORRECTION: Reconnexion indépendante du context
        if (_shouldReconnect) {
          debugPrint('🔄 [WebSocket] Will attempt reconnection in 3s');
          Future.delayed(const Duration(seconds: 3), () {
            if (_shouldReconnect && _status == SocketStatus.disconnected) {
              _attemptReconnection();
            }
          });
        } else {
          debugPrint('⚠️ [WebSocket] Reconnexion désactivée');
        }
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
        debugPrint(
          '❌ [WebSocket] Reconnection failed after all attempts: $error',
        );
        _updateStatus(SocketStatus.error);
      })
      // v2 message:new : payload v2 complet (Map<String,dynamic>)
      ..on('message:new', (data) {
        _updateActivityMetrics();
        _messagesReceived++;

        debugPrint(
          '📨 [WebSocket] ========== MESSAGE REÇU VIA WEBSOCKET ==========',
        );
        debugPrint('📨 [WebSocket] Total messages reçus: $_messagesReceived');
        debugPrint('📨 [WebSocket] Type de données: ${data.runtimeType}');

        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          final convId = map['convId'] as String?;
          final messageId = map['messageId'] as String?;
          final sender = map['sender'] as Map?;
          final senderId = sender?['userId'] as String?;

          debugPrint('📨 [WebSocket] Message détails:');
          debugPrint('📨 [WebSocket]   convId: $convId');
          debugPrint('📨 [WebSocket]   messageId: $messageId');
          debugPrint('📨 [WebSocket]   senderId: $senderId');
          debugPrint(
            '📨 [WebSocket]   Clés du payload: ${map.keys.join(", ")}',
          );
          debugPrint(
            '📨 [WebSocket] Callback onNewMessageV2: ${onNewMessageV2 != null ? "✅ BRANCHÉ" : "❌ NON BRANCHÉ"}',
          );

          if (onNewMessageV2 != null) {
            debugPrint('📨 [WebSocket] Appel du callback onNewMessageV2...');
            try {
              onNewMessageV2!(map);
              debugPrint(
                '📨 [WebSocket] ✅ Callback onNewMessageV2 appelé avec succès',
              );
            } catch (e, stackTrace) {
              debugPrint(
                '❌ [WebSocket] Erreur dans le callback onNewMessageV2: $e',
              );
              debugPrint('❌ [WebSocket] Stack trace: $stackTrace');
            }
          } else {
            debugPrint(
              '⚠️ [WebSocket] ⚠️ Callback onNewMessageV2 non branché !',
            );
            debugPrint('⚠️ [WebSocket] Le message ne sera pas traité');
          }
        } else {
          debugPrint(
            '⚠️ [WebSocket] Message reçu mais format invalide: ${data.runtimeType}',
          );
          debugPrint('⚠️ [WebSocket] Données reçues: $data');
        }

        debugPrint(
          '📨 [WebSocket] ============================================',
        );
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
      ..on('presence:conversation:batch', (data) {
        _updateActivityMetrics();

        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final conversationId = m['conversationId'] as String?;
          final presences = m['presences'] as List<dynamic>?;

          if (conversationId != null && presences != null) {
            final presencesList =
                presences.map((p) => Map<String, dynamic>.from(p)).toList();

            onPresenceConversationBatch?.call(conversationId, presencesList);
          }
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
      ..on('device:revoked', (data) async {
        if (data is! Map) return;
        final payload = Map<String, dynamic>.from(data);
        final deviceId = payload['deviceId'];
        final rawGroupIds = payload['groupIds'];
        if (deviceId is! String || rawGroupIds is! List) return;
        final groupIds = rawGroupIds.whereType<String>().toList(
          growable: false,
        );
        onDeviceRevoked?.call(deviceId, groupIds);
        if (_authProvider?.currentDeviceId == deviceId) {
          disconnect();
          await _authProvider?.refreshDeviceTrust(showChecking: false);
        }
      })
      ..on('device:key-directory-changed', (data) {
        if (data is! Map) return;
        final payload = Map<String, dynamic>.from(data);
        final groupId = payload['groupId'];
        final deviceId = payload['deviceId'];
        if (groupId is String && deviceId is String) {
          onDeviceKeyDirectoryChanged?.call(groupId, deviceId);
        }
      })
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
          // SÉCURITÉ: Les données peuvent être minimales (ping uniquement)
          final groupId = m['groupId'] as String?;
          final creatorId = m['creatorId'] as String?;
          onGroupCreated?.call(groupId, creatorId);
        }
      })
      ..on('conversation:created', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          // SÉCURITÉ: Les données peuvent être minimales (ping uniquement)
          final convId = m['convId'] as String?;
          final groupId = m['groupId'] as String?;
          final creatorId = m['creatorId'] as String?;
          onConversationCreated?.call(convId, groupId, creatorId);
        }
      })
      ..on('group:member_joined', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          // SÉCURITÉ: Les données peuvent être minimales (ping uniquement)
          final groupId = m['groupId'] as String?;
          final userId = m['userId'] as String?;
          final approverId = m['approverId'] as String?;
          onGroupMemberJoined?.call(groupId, userId, approverId);
        }
      })
      ..on('group:joined', (data) {
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          // SÉCURITÉ: Les données peuvent être minimales (ping uniquement)
          final groupId = m['groupId'] as String?;
          final userId = m['userId'] as String?;
          final approverId = m['approverId'] as String?;
          onGroupJoined?.call(groupId, userId, approverId);
        }
      })
      ..onError((err) {
        _handleError('Erreur WebSocket: $err');
      })
      ..on('connect_error', (err) {
        _handleError('Erreur de connexion: $err');
        if (err.toString().contains('device authorization required')) {
          disconnect();
          unawaited(_authProvider?.refreshDeviceTrust(showChecking: false));
        }
      });
  }

  void subscribeConversation(String conversationId) {
    // ✅ OPTIMISATION: Vérifier si déjà abonné AVANT d'envoyer la requête
    if (_subscribedConversations.contains(conversationId)) {
      debugPrint(
        '📡 [WebSocket] Conversation déjà abonnée, ignorée: $conversationId',
      );
      return; // Ne pas envoyer de requête redondante
    }

    debugPrint(
      '📡 [WebSocket] Tentative d\'abonnement à la conversation: $conversationId',
    );
    debugPrint('📡 [WebSocket] Statut actuel: $_status');
    debugPrint('📡 [WebSocket] Socket null? ${_socket == null}');

    // Ajouter à la liste des abonnements persistants
    _subscribedConversations.add(conversationId);
    debugPrint(
      '📡 [WebSocket] Conversations abonnées: ${_subscribedConversations.length}',
    );

    if (_status != SocketStatus.connected || _socket == null) {
      // Si pas connecté, ajouter aux abonnements en attente
      _pendingSubscriptions.add(conversationId);
      debugPrint(
        '⚠️ [WebSocket] WebSocket non connecté, abonnement mis en attente: $conversationId',
      );
      return;
    }

    debugPrint('📡 [WebSocket] Envoi de conv:subscribe pour $conversationId');
    _socket!.emitWithAck(
      'conv:subscribe',
      {'convId': conversationId},
      ack: (resp) {
        debugPrint(
          '📡 [WebSocket] Réponse conv:subscribe pour $conversationId: $resp',
        );
        if (resp != null) {
          if (resp is Map) {
            final success = resp['success'] as bool?;
            if (success == true) {
              debugPrint(
                '✅ [WebSocket] Abonnement réussi à la conversation $conversationId',
              );
            } else {
              final error = resp['error'] as String?;
              debugPrint(
                '❌ [WebSocket] Échec de l\'abonnement à la conversation $conversationId: $error',
              );
            }
          } else {
            debugPrint(
              '📡 [WebSocket] Réponse conv:subscribe (format inattendu): $resp (type: ${resp.runtimeType})',
            );
          }
        } else {
          debugPrint(
            '⚠️ [WebSocket] Réponse conv:subscribe est null (timeout ou pas de réponse)',
          );
        }
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

  /// ✅ NOUVEAU: S'abonne à plusieurs conversations en une seule requête batch
  Future<Map<String, dynamic>> subscribeConversationsBatch(
    List<String> conversationIds,
  ) async {
    final requestedConversationIds = conversationIds.toSet().toList();
    if (requestedConversationIds.isEmpty) {
      return {'success': false, 'error': 'No conversation IDs provided'};
    }
    if (requestedConversationIds.length > maxSocketBatchConversations) {
      var subscribed = 0;
      var alreadySubscribed = 0;
      var unauthorized = 0;
      final subscribedIds = <String>[];
      for (
        var offset = 0;
        offset < requestedConversationIds.length;
        offset += maxSocketBatchConversations
      ) {
        final end =
            (offset + maxSocketBatchConversations <
                    requestedConversationIds.length)
                ? offset + maxSocketBatchConversations
                : requestedConversationIds.length;
        final result = await subscribeConversationsBatch(
          requestedConversationIds.sublist(offset, end),
        );
        if (result['success'] != true) return result;
        subscribed += result['subscribed'] as int? ?? 0;
        alreadySubscribed += result['alreadySubscribed'] as int? ?? 0;
        unauthorized += result['unauthorized'] as int? ?? 0;
        subscribedIds.addAll(
          (result['convIds'] as List<dynamic>? ?? const []).map(
            (id) => id.toString(),
          ),
        );
      }
      return {
        'success': true,
        'subscribed': subscribed,
        'alreadySubscribed': alreadySubscribed,
        'unauthorized': unauthorized,
        'convIds': subscribedIds,
      };
    }

    // Filtrer les conversations déjà abonnées
    final newConversations =
        requestedConversationIds
            .where((id) => !_subscribedConversations.contains(id))
            .toList();

    if (newConversations.isEmpty) {
      debugPrint('📡 [WebSocket] Toutes les conversations sont déjà abonnées');
      return {
        'success': true,
        'subscribed': 0,
        'alreadySubscribed': requestedConversationIds.length,
        'unauthorized': 0,
        'convIds': [],
      };
    }

    // ✅ CORRECTION: Ne PAS ajouter aux abonnements persistants avant confirmation serveur
    debugPrint(
      '📡 [WebSocket] Batch subscription: ${newConversations.length} nouvelles conversations',
    );

    if (_status != SocketStatus.connected || _socket == null) {
      // Si pas connecté, ajouter aux abonnements en attente
      _pendingSubscriptions.addAll(newConversations);
      debugPrint(
        '⚠️ [WebSocket] WebSocket non connecté, abonnements mis en attente',
      );
      return {
        'success': false,
        'error': 'WebSocket not connected',
        'pending': newConversations.length,
      };
    }

    debugPrint(
      '📡 [WebSocket] Envoi de conv:subscribe:batch pour ${newConversations.length} conversations',
    );

    final completer = Completer<Map<String, dynamic>>();
    bool timeoutOccurred = false;

    _socket!.emitWithAck(
      'conv:subscribe:batch',
      {'convIds': newConversations},
      ack: (resp) {
        if (timeoutOccurred) {
          debugPrint(
            '⚠️ [WebSocket] Réponse batch reçue après timeout, ignorée',
          );
          return;
        }

        if (resp != null && resp is Map) {
          final success = resp['success'] as bool? ?? false;
          if (success) {
            final subscribed = resp['subscribed'] as int? ?? 0;
            final alreadySubscribed = resp['alreadySubscribed'] as int? ?? 0;
            final unauthorized = resp['unauthorized'] as int? ?? 0;
            final subscribedConvIds = resp['convIds'] as List<dynamic>? ?? [];

            // ✅ CORRECTION: Ajouter aux abonnements persistants SEULEMENT après confirmation serveur
            final actualSubscribed =
                subscribedConvIds.map((id) => id.toString()).toList();
            _subscribedConversations.addAll(actualSubscribed);
            debugPrint(
              '✅ [WebSocket] Batch subscription réussie: $subscribed nouveaux, $alreadySubscribed déjà abonnés, $unauthorized non autorisés',
            );
          }
          completer.complete(Map<String, dynamic>.from(resp));
        } else {
          completer.completeError('Invalid response from batch subscription');
        }
      },
    );

    // ✅ CORRECTION: Timeout augmenté à 20 secondes et gestion améliorée
    Future.delayed(const Duration(seconds: 20), () {
      if (!completer.isCompleted) {
        timeoutOccurred = true;
        debugPrint('⚠️ [WebSocket] Batch subscription timeout après 20s');
        completer.completeError('Batch subscription timeout');
      }
    });

    try {
      final result = await completer.future;
      return result;
    } catch (e) {
      // ✅ CORRECTION: En cas d'erreur, ne pas ajouter aux abonnements pour permettre le fallback
      debugPrint('❌ [WebSocket] Erreur batch subscription: $e');
      // Ne pas ajouter aux _subscribedConversations pour permettre le fallback individuel
      rethrow;
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
    if (_subscribedConversations.isEmpty) {
      return;
    }

    debugPrint(
      '📡 [WebSocket] Réabonnement aux conversations: ${_subscribedConversations.length} conversations',
    );

    // ✅ OPTIMISÉ: Utiliser batch subscription si plus de 5 conversations
    if (_subscribedConversations.length > 5) {
      subscribeConversationsBatch(_subscribedConversations.toList()).catchError(
        (error) {
          debugPrint('❌ [WebSocket] Erreur batch réabonnement: $error');
          // Fallback: abonner une par une
          for (final convId in _subscribedConversations) {
            subscribeConversation(convId);
          }
          return <String, dynamic>{'success': false, 'error': error.toString()};
        },
      );
    } else {
      // Pour peu de conversations, abonner une par une
      for (final convId in _subscribedConversations) {
        subscribeConversation(convId);
      }
    }

    // Traiter les abonnements en attente
    if (_pendingSubscriptions.isNotEmpty) {
      final pendingList = _pendingSubscriptions.toList();
      _pendingSubscriptions.clear();

      // ✅ OPTIMISÉ: Utiliser batch pour les abonnements en attente aussi
      if (pendingList.length > 5) {
        subscribeConversationsBatch(pendingList).catchError((error) {
          debugPrint(
            '❌ [WebSocket] Erreur batch abonnements en attente: $error',
          );
          // Fallback: abonner une par une
          for (final convId in pendingList) {
            subscribeConversation(convId);
          }
          return <String, dynamic>{'success': false, 'error': error.toString()};
        });
      } else {
        for (final convId in pendingList) {
          subscribeConversation(convId);
        }
      }
    }
  }

  /// Gestion intelligente des abonnements avec métriques
  void _updateActivityMetrics() {
    _lastActivity = DateTime.now();
    _eventsReceived++;
  }

  /// Nettoie les abonnements obsolètes
  void cleanupSubscriptions() {
    final now = DateTime.now();
    if (_lastActivity != null &&
        now.difference(_lastActivity!).inMinutes > 30) {
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

  /// Déconnecte le WebSocket
  /// [shouldReconnect] : si false, désactive la reconnexion automatique
  void disconnect({bool shouldReconnect = false}) {
    _shouldReconnect = shouldReconnect;
    _disposeSocket();
    _updateStatus(SocketStatus.disconnected);
    debugPrint(
      '🔌 [WebSocket] Disconnected (shouldReconnect: $shouldReconnect)',
    );
  }

  void _disposeSocket() {
    _socket?.clearListeners();
    _socket?.disconnect();
    _socket = null;
  }

  /// ✅ NOUVEAU: Dispose toutes les ressources
  void dispose() {
    _networkSubscription?.cancel();
    _networkSubscription = null;
    _disposeSocket();
    _statusController.close();
  }

  void _updateStatus(SocketStatus newStatus) {
    _status = newStatus;
    _statusController.add(_status);
  }

  void _handleError(String message) {
    _updateStatus(SocketStatus.error);
  }
}
