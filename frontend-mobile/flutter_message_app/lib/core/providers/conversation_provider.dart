import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/models/conversation.dart';
import 'package:flutter_message_app/core/models/message.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/services/api_service.dart';
import 'package:flutter_message_app/core/services/snackbar_service.dart';
import 'package:flutter_message_app/core/services/websocket_service.dart';
import 'package:flutter_message_app/core/services/key_directory_service.dart';
import 'package:flutter_message_app/core/services/notification_service.dart';
import 'package:flutter_message_app/core/services/notification_badge_service.dart';
import 'package:flutter_message_app/core/services/global_presence_service.dart';
import 'package:flutter_message_app/core/services/local_message_storage.dart';
import 'package:flutter_message_app/core/services/message_key_cache.dart';
import 'package:flutter_message_app/core/services/persistent_message_key_cache.dart';
import 'package:flutter_message_app/core/services/performance_benchmark.dart';
import 'package:flutter_message_app/core/services/navigation_tracker_service.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_message_app/core/crypto/message_cipher_v2.dart';
import 'package:flutter_message_app/core/crypto/message_envelope_verifier.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';

/// Gère l'état des conversations et des messages.
class ConversationProvider extends ChangeNotifier {
  final ApiService _apiService;
  final WebSocketService _webSocketService;
  late final KeyDirectoryService _keyDirectory;
  final AuthProvider _authProvider;
  String? _keyCacheUserId;

  /// 🚀 OPTIMISATION: Limite maximale de messages en mémoire par conversation
  /// Au-delà de cette limite, les messages les plus anciens sont automatiquement retirés
  /// Les messages sont déjà sauvegardés dans LocalMessageStorage, donc pas de perte de données
  static const int _maxMessagesInMemory = 200;

  List<Conversation> _conversations = <Conversation>[];

  /// ✅ OPTIMISATION: Flag pour éviter les appels multiples à fetchConversations
  bool _conversationsLoaded = false;
  DateTime? _lastConversationsLoad;
  // ✅ CORRECTION: Réduire le cache à 10 secondes pour ne pas bloquer les groupes
  static const Duration _conversationsCacheDuration = Duration(seconds: 10);

  /// Cache local des messages, par conversationId
  final Map<String, List<Message>> _messages = {};

  /// Cache mémoire des messages déchiffrés (session courante uniquement)
  /// ⚠️ IMPORTANT: Ce cache n'est PAS persisté pour des raisons de sécurité
  final Map<String, String> _decryptedCache = {};

  /// Presence: userId -> online
  final Map<String, bool> _userOnline = <String, bool>{};

  /// Presence spécifique aux conversations: conversationId -> userId -> online
  final Map<String, Map<String, bool>> _conversationPresence =
      <String, Map<String, bool>>{};

  /// Read receipts per conversation
  final Map<String, List<Map<String, dynamic>>> _readersByConv =
      <String, List<Map<String, dynamic>>>{};

  /// Compteurs de messages non lus par conversation
  final Map<String, int> _unreadCounts = <String, int>{};

  /// Utilisateurs en train de taper par conversation
  final Map<String, Set<String>> _typingUsers = <String, Set<String>>{};

  /// Cache des pseudos des utilisateurs par userId
  final Map<String, String> _userUsernames = <String, String>{};

  /// 🚀 OPTIMISATION: Batching des notifications pour éviter les freezes
  /// Accumule les notifications et les envoie par batch toutes les 100ms
  Timer? _notificationBatchTimer;
  bool _pendingNotification = false;

  /// Notifie les listeners de manière batchée pour éviter les freezes
  void _notifyListenersBatched() {
    _pendingNotification = true;

    // Annuler le timer précédent s'il existe
    _notificationBatchTimer?.cancel();

    // Programmer une notification dans 100ms (ou immédiatement si c'est la première)
    _notificationBatchTimer = Timer(const Duration(milliseconds: 100), () {
      if (_pendingNotification) {
        _pendingNotification = false;
        notifyListeners();
      }
    });
  }

  /// Force une notification immédiate (pour les actions critiques)
  void _notifyListenersImmediate() {
    _notificationBatchTimer?.cancel();
    _pendingNotification = false;
    notifyListeners();
  }

  /// Obtient le username d'un utilisateur depuis le cache
  String getUsernameForUser(String userId) {
    return _userUsernames[userId] ?? '';
  }

  /// Met en cache le username d'un utilisateur
  void cacheUsername(String userId, String username) {
    if (username.isNotEmpty) {
      _userUsernames[userId] = username;
    }
  }

  ConversationProvider(AuthProvider authProvider)
    : _apiService = ApiService(authProvider),
      _webSocketService = WebSocketService.instance,
      _authProvider = authProvider {
    _keyDirectory = KeyDirectoryService(_apiService);
    _keyCacheUserId = _authProvider.userId;
    _authProvider.addListener(_handleAuthIdentityChange);

    // Initialiser le stockage local (async, non-bloquant)
    LocalMessageStorage.instance.initialize().catchError((e) {
      debugPrint('⚠️ Erreur initialisation stockage local: $e');
    });

    // Charger le cache de déchiffrement au démarrage de manière synchrone
    _initializeCache();

    // Initialiser la présence de l'utilisateur actuel comme en ligne
    final currentUserId = _authProvider.userId;
    if (currentUserId != null) {
      _userOnline[currentUserId] = true;
      debugPrint(
        '👥 [Presence] Initialized current user $currentUserId as online',
      );
    }

    // CORRECTION: Utiliser le service global de présence au lieu de configurer nos propres callbacks
    _setupGlobalPresenceListener();

    // Configurer les autres callbacks WebSocket de manière asynchrone
    _setupWebSocketCallbacksAsync();
  }

  Future<String> _currentDeviceId() async {
    final deviceId = _authProvider.currentDeviceId;
    if (!_authProvider.canUseMessaging || deviceId == null) {
      throw StateError('an active account device is required');
    }
    return deviceId;
  }

  void _handleAuthIdentityChange() {
    final nextUserId = _authProvider.userId;
    if (_keyCacheUserId != nextUserId) {
      _decryptedCache.clear();
      _keyDirectory.clearAllCaches().catchError((_) {});
      _keyCacheUserId = nextUserId;
    }
  }

  @override
  void dispose() {
    _authProvider.removeListener(_handleAuthIdentityChange);
    _notificationBatchTimer?.cancel();
    super.dispose();
  }

  /// Configure l'écoute du service global de présence
  void _setupGlobalPresenceListener() {
    debugPrint('👥 [ConversationProvider] Setting up global presence listener');

    // Écouter les changements de présence globale
    GlobalPresenceService().addListener(() {
      debugPrint(
        '👥 [ConversationProvider] Global presence changed, updating local state',
      );
      _syncWithGlobalPresence();
      // 🚀 OPTIMISATION: Batching pour les mises à jour de présence (non-critique)
      _notifyListenersBatched();
    });

    // Synchroniser l'état initial avec le service global
    _syncWithGlobalPresence();
  }

  /// Synchronise l'état local avec le service global de présence
  void _syncWithGlobalPresence() {
    final globalPresence = GlobalPresenceService();

    // Synchroniser la présence générale
    _userOnline.clear();
    _userOnline.addAll(globalPresence.allUsersOnline);

    // Synchroniser la présence des conversations
    _conversationPresence.clear();
    _conversationPresence.addAll(globalPresence.allConversationPresence);

    debugPrint(
      '👥 [ConversationProvider] Synced with global presence: $_userOnline',
    );
    debugPrint(
      '👥 [ConversationProvider] Synced conversation presence: $_conversationPresence',
    );
  }

  /// Configure les callbacks WebSocket de manière asynchrone
  void _setupWebSocketCallbacksAsync() {
    // Les callbacks de présence sont maintenant gérés par le service global
    debugPrint(
      '👥 [ConversationProvider] Presence callbacks handled by global service',
    );

    // Attendre un peu pour les autres callbacks moins critiques
    Future.delayed(const Duration(milliseconds: 100), () {
      debugPrint(
        '👥 [ConversationProvider] Setting up WebSocket callbacks asynchronously',
      );
      _setupWebSocketCallbacks();
    });
  }

  /// Configure les callbacks WebSocket une seule fois
  void _setupWebSocketCallbacks() {
    // Ne définir les callbacks que s'ils ne sont pas déjà définis
    if (_webSocketService.onNewMessageV2 == null) {
      _webSocketService.onNewMessageV2 = _onWebSocketNewMessageV2;
      debugPrint('✅ [ConversationProvider] Callback onNewMessageV2 branché');
    } else {
      debugPrint(
        '⚠️ [ConversationProvider] Callback onNewMessageV2 déjà branché',
      );
    }
    // Les callbacks de présence sont maintenant gérés par le service global
    debugPrint(
      '👥 [ConversationProvider] Presence callbacks handled by global service',
    );
    // ✅ NOUVEAU: Gérer les événements de présence batch
    if (_webSocketService.onPresenceConversationBatch == null) {
      _webSocketService.onPresenceConversationBatch =
          _onPresenceConversationBatch;
      debugPrint(
        '✅ [ConversationProvider] Callback onPresenceConversationBatch branché',
      );
    }
    if (_webSocketService.onConvRead == null) {
      _webSocketService.onConvRead = _onConvRead;
    }
    if (_webSocketService.onUserAdded == null) {
      _webSocketService.onUserAdded = _onWebSocketUserAdded;
    }
    _webSocketService.onDeviceRevoked = _onDeviceRevoked;
    _webSocketService.onDeviceKeyDirectoryChanged =
        _onDeviceKeyDirectoryChanged;
    if (_webSocketService.onConversationJoined == null) {
      _webSocketService.onConversationJoined = _onWebSocketConversationJoined;
    }
    // Ajouter les callbacks pour les indicateurs de frappe
    if (_webSocketService.onTypingStart == null) {
      _webSocketService.onTypingStart = _onTypingStart;
    }
    if (_webSocketService.onTypingStop == null) {
      _webSocketService.onTypingStop = _onTypingStop;
    }
    // Ajouter les callbacks pour les nouveaux groupes et conversations
    if (_webSocketService.onGroupCreated == null) {
      _webSocketService.onGroupCreated = _onWebSocketGroupCreated;
    }
    if (_webSocketService.onConversationCreated == null) {
      _webSocketService.onConversationCreated = _onWebSocketConversationCreated;
    }
  }

  void _onDeviceRevoked(String deviceId, List<String> groupIds) {
    for (final groupId in groupIds) {
      unawaited(_keyDirectory.invalidateGroupDirectory(groupId));
    }
    if (_authProvider.currentDeviceId == deviceId) {
      _decryptedCache.clear();
      MessageKeyCache.instance.clear();
      PersistentMessageKeyCache.instance.clear().catchError((_) {});
      _messages.clear();
      _notifyListenersImmediate();
    }
  }

  void _onDeviceKeyDirectoryChanged(String groupId, String deviceId) {
    unawaited(_keyDirectory.invalidateGroupDirectory(groupId));
  }

  /// Initialise le cache de déchiffrement (préserve les messages déjà déchiffrés)
  Future<void> _initializeCache() async {
    // CORRECTION: Nettoyer les données obsolètes au démarrage
    await _cleanupObsoleteData();

    // Ne pas vider le cache pour préserver les messages déjà déchiffrés
    debugPrint(
      '🚀 ConversationProvider initialisé - Cache de déchiffrement préservé (${_decryptedCache.length} messages)',
    );
  }

  /// Nettoie les données obsolètes (conversations supprimées, messages anciens, etc.)
  Future<void> _cleanupObsoleteData() async {
    try {
      // Nettoyer les messages des conversations qui n'existent plus
      final validConvIds = _conversations.map((c) => c.conversationId).toSet();
      final obsoleteConvIds =
          _messages.keys.where((id) => !validConvIds.contains(id)).toList();

      for (final convId in obsoleteConvIds) {
        debugPrint('🧹 Cleaning up obsolete conversation: $convId');
        _messages.remove(convId);
        _readersByConv.remove(convId);
        _unreadCounts.remove(convId);
        _typingUsers.remove(convId);
      }

      // Nettoyer les messages déchiffrés des conversations supprimées
      final obsoleteMessageIds = <String>[];
      for (final msgId in _decryptedCache.keys) {
        // Vérifier si le message appartient à une conversation valide
        bool messageExists = false;
        for (final messages in _messages.values) {
          if (messages.any((msg) => msg.id == msgId)) {
            messageExists = true;
            break;
          }
        }
        if (!messageExists) {
          obsoleteMessageIds.add(msgId);
        }
      }

      for (final msgId in obsoleteMessageIds) {
        debugPrint('🧹 Cleaning up obsolete message: $msgId');
        _decryptedCache.remove(msgId);
      }

      if (obsoleteConvIds.isNotEmpty || obsoleteMessageIds.isNotEmpty) {
        debugPrint(
          '🧹 Cleanup completed: ${obsoleteConvIds.length} conversations, ${obsoleteMessageIds.length} messages',
        );
      }
    } catch (e) {
      debugPrint('⚠️ Error during cleanup: $e');
    }
  }

  /// 🚀 OPTIMISATION: Nettoie les messages anciens si la limite est dépassée
  /// Garde uniquement les N derniers messages (les plus récents)
  /// Les messages supprimés sont déjà sauvegardés dans LocalMessageStorage, donc pas de perte de données
  void _trimMessagesIfNeeded(String conversationId) {
    final messages = _messages[conversationId];
    if (messages == null || messages.length <= _maxMessagesInMemory) {
      return; // Pas besoin de nettoyer
    }

    // Garder les N derniers messages (les plus récents)
    // Les messages sont triés par timestamp croissant (plus ancien en premier)
    final toKeep = messages.sublist(messages.length - _maxMessagesInMemory);
    final removedCount = messages.length - toKeep.length;

    _messages[conversationId] = toKeep;

    // Nettoyer aussi le cache de déchiffrement pour les messages supprimés
    final keptIds = toKeep.map((m) => m.id).toSet();
    final removedIds =
        _decryptedCache.keys.where((id) => !keptIds.contains(id)).toList();
    for (final id in removedIds) {
      _decryptedCache.remove(id);
    }

    debugPrint(
      '🧹 Trimmed messages for $conversationId: kept ${toKeep.length} most recent, removed $removedCount old messages',
    );
  }

  Future<void> postRead(String conversationId) async {
    try {
      await _apiService.postConversationRead(conversationId: conversationId);
      // Marquer la conversation comme lue localement
      markConversationAsRead(conversationId);
    } catch (_) {}
  }

  /// Liste des conversations chargées.
  List<Conversation> get conversations => _conversations;

  /// Messages en mémoire pour une conversation donnée.
  List<Message> messagesFor(String conversationId) =>
      _messages[conversationId] ?? <Message>[];

  String? groupIdForConversation(String conversationId) {
    for (final conversation in _conversations) {
      if (conversation.conversationId == conversationId) {
        return conversation.groupId;
      }
    }
    return null;
  }

  /// Déchiffre un message à la demande après authentification complète.
  Future<String?> decryptMessageIfNeeded(Message message) async {
    final msgId = message.id;

    if (message.decryptedText != null && message.signatureValid == true) {
      _decryptedCache[msgId] = message.decryptedText!;
      return message.decryptedText;
    }

    if (message.signatureValid == true && _decryptedCache.containsKey(msgId)) {
      return _decryptedCache[msgId];
    }

    // Une ancienne version a pu laisser du texte non vérifié en mémoire.
    _decryptedCache.remove(msgId);
    if (message.signatureValid != true) {
      message.decryptedText = null;
    }

    try {
      if (message.v2Data == null) {
        return _markMessageUnavailable(message, '[Message indisponible]');
      }

      final currentUserId = _authProvider.userId;
      if (currentUserId == null) {
        throw Exception('Utilisateur non authentifié');
      }

      final myDeviceId = await _currentDeviceId();
      final groupId = groupIdForConversation(message.conversationId);
      if (groupId == null) {
        throw const MessageAuthenticationException('unknown_conversation');
      }

      final result = await MessageCipherV2.decryptVerified(
        groupId: groupId,
        expectedConversationId: message.conversationId,
        myUserId: currentUserId,
        myDeviceId: myDeviceId,
        messageV2: message.v2Data!,
        keyDirectory: _keyDirectory,
      );

      final decryptedText = utf8.decode(result['decryptedText'] as Uint8List);
      message.signatureValid = true;
      message.decryptedText = decryptedText;
      _decryptedCache[msgId] = decryptedText;

      LocalMessageStorage.instance.saveMessage(message).catchError((e) {
        debugPrint('⚠️ Erreur sauvegarde signatureValid: $e');
      });
      _notifyListenersBatched();
      return decryptedText;
    } on MessageAuthenticationException catch (error) {
      debugPrint('Message rejeté pendant l’authentification: ${error.code}');
      return _markMessageUnavailable(message, '[Message non authentifié]');
    } catch (_) {
      debugPrint('Échec du déchiffrement du message $msgId');
      return _markMessageUnavailable(message, '[Message indisponible]');
    }
  }

  String _markMessageUnavailable(Message message, String label) {
    _decryptedCache.remove(message.id);
    message.signatureValid = false;
    message.decryptedText = label;
    _notifyListenersBatched();
    return label;
  }

  /// Déchiffrement des messages visibles AVEC vérification de signature
  Future<void> decryptVisibleMessagesFast(
    String conversationId, {
    required int visibleCount,
  }) async {
    final messages = _messages[conversationId] ?? [];
    if (messages.isEmpty) return;

    // Déchiffrer seulement les 3 derniers messages (les plus importants)
    final toDecrypt =
        messages.length > 3 ? messages.sublist(messages.length - 3) : messages;

    // CORRECTION: Déchiffrer avec vérification de signature (utiliser decryptMessageIfNeeded)
    final futures = <Future<void>>[];
    for (final msg in toDecrypt) {
      if (msg.decryptedText == null && msg.v2Data != null) {
        futures.add(decryptMessageIfNeeded(msg).then((_) => null));
      }
    }

    if (futures.isNotEmpty) {
      await Future.wait(futures);
      // 🚀 OPTIMISATION: Batching pour éviter les freezes
      _notifyListenersBatched();
    }
  }

  /// Getter pour accéder au service de clés de groupe
  KeyDirectoryService get keyDirectory => _keyDirectory;

  /// Invalide les caches lors de révocation device
  Future<void> invalidateCachesForDevice(
    String groupId,
    String deviceId,
  ) async {
    // Invalider group keys
    await _keyDirectory.invalidateGroupDirectory(groupId);

    // Invalider message keys
    await PersistentMessageKeyCache.instance.invalidateKeysForDevice(
      groupId,
      deviceId,
    );
  }

  /// Pré-charge les clés de groupe pour améliorer les performances de déchiffrement
  Future<void> preloadGroupKeys(String conversationId) async {
    try {
      final conversation = _conversations.firstWhere(
        (c) => c.conversationId == conversationId,
        orElse: () => throw Exception('Conversation not found'),
      );

      final groupId = conversation.groupId;

      // Pré-charger les clés de groupe en arrière-plan
      await _keyDirectory.getGroupDevices(groupId);
      debugPrint('🔑 Clés de groupe pré-chargées pour $groupId');
    } catch (e) {
      debugPrint('⚠️ Erreur pré-chargement clés groupe: $e');
    }
  }

  /// Déchiffre les messages autour de la position de scroll (pour les messages anciens)
  Future<void> decryptMessagesAroundScrollPosition(
    String conversationId, {
    required int scrollIndex,
    required int visibleCount,
  }) async {
    final messages = _messages[conversationId] ?? [];
    if (messages.isEmpty) return;

    // Calculer la plage de messages à déchiffrer autour de la position de scroll
    final startIndex = math.max(0, scrollIndex - visibleCount ~/ 2);
    final endIndex = math.min(messages.length, scrollIndex + visibleCount ~/ 2);

    final toDecrypt = messages.sublist(startIndex, endIndex);

    // CORRECTION: Déchiffrer par très petits groupes pour éviter le freeze
    const batchSize =
        1; // Déchiffrer seulement 1 message à la fois pour les anciens
    const delayBetweenBatches = 300; // Pause plus longue

    for (int i = 0; i < toDecrypt.length; i += batchSize) {
      final batch = toDecrypt.skip(i).take(batchSize).toList();
      final futures = <Future<void>>[];

      for (final msg in batch) {
        if (msg.decryptedText == null && msg.v2Data != null) {
          futures.add(decryptMessageIfNeeded(msg));
        }
      }

      // Attendre la fin du groupe actuel
      if (futures.isNotEmpty) {
        await Future.wait(futures);
        // 🚀 OPTIMISATION: Batching pour éviter les freezes
        _notifyListenersBatched();

        // Petite pause pour éviter le freeze de l'UI
        if (i + batchSize < toDecrypt.length) {
          await Future.delayed(
            const Duration(milliseconds: delayBetweenBatches),
          );
        }
      }
    }
  }

  /// CORRECTION: Déchiffrement uniquement sur demande (ultra-fluide)
  Future<void> decryptMessageOnDemand(
    String conversationId,
    String messageId,
  ) async {
    final messages = _messages[conversationId] ?? [];
    final message = messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () => throw Exception('Message not found'),
    );

    if (message.decryptedText == null && message.v2Data != null) {
      await decryptMessageIfNeeded(message);
      // 🚀 OPTIMISATION: Batching pour éviter les freezes
      _notifyListenersBatched();
    }
  }

  /// Déchiffre les messages en arrière-plan (pour l'expérience utilisateur)
  Future<void> decryptMessagesInBackground(String conversationId) async {
    final messages = _messages[conversationId] ?? [];
    if (messages.isEmpty) return;

    // Déchiffrer tous les messages non déchiffrés en arrière-plan
    final futures = <Future<void>>[];
    int processed = 0;

    for (final msg in messages) {
      if (msg.decryptedText == null && msg.v2Data != null) {
        futures.add(
          decryptMessageIfNeeded(msg).then((_) {
            processed++;
            // 🚀 OPTIMISATION: Notifier tous les 10 messages déchiffrés (au lieu de 5) pour réduire les freezes
            if (processed % 10 == 0) {
              _notifyListenersBatched();
            }
          }),
        );
      }
    }

    // Attendre la fin et notifier une dernière fois
    if (futures.isNotEmpty) {
      await Future.wait(futures);
      // 🚀 OPTIMISATION: Batching pour éviter les freezes
      _notifyListenersBatched();
    }
  }

  bool isUserOnline(String userId) {
    final isOnline = _userOnline[userId] == true;
    debugPrint(
      '👥 [Presence] Checking if $userId is online: $isOnline (map: $_userOnline)',
    );
    return isOnline;
  }

  /// Vérifie si un utilisateur est en ligne dans une conversation spécifique
  bool isUserOnlineInConversation(String conversationId, String userId) {
    return _conversationPresence[conversationId]?[userId] ?? false;
  }

  /// Obtient tous les utilisateurs en ligne dans une conversation
  List<String> getOnlineUsersInConversation(String conversationId) {
    final presence = _conversationPresence[conversationId];
    if (presence == null) return [];

    return presence.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toList();
  }

  int onlineUsersCount() => _userOnline.values.where((v) => v == true).length;
  List<Map<String, dynamic>> readersFor(String conversationId) =>
      _readersByConv[conversationId] ?? const <Map<String, dynamic>>[];

  /// Obtient le nombre de messages non lus pour une conversation
  int getUnreadCount(String conversationId) =>
      _unreadCounts[conversationId] ?? 0;

  /// Marque une conversation comme lue (remet le compteur à zéro)
  void markConversationAsRead(String conversationId) {
    _unreadCounts[conversationId] = 0;
    // 🚀 OPTIMISATION: Notification immédiate pour action utilisateur (critique)
    _notifyListenersImmediate();
  }

  /// Obtient la liste des utilisateurs en train de taper pour une conversation
  List<String> getTypingUsers(String conversationId) {
    return _typingUsers[conversationId]?.toList() ?? [];
  }

  /// Obtient les pseudos des utilisateurs en train de taper pour une conversation
  List<String> getTypingUsernames(String conversationId) {
    final typingUserIds = _typingUsers[conversationId]?.toList() ?? [];
    final usernames = <String>[];

    for (final userId in typingUserIds) {
      // Utiliser le cache des pseudos si disponible, sinon utiliser l'ID tronqué
      final username =
          _userUsernames[userId] ??
          (userId.length > 8 ? '${userId.substring(0, 8)}...' : userId);
      usernames.add(username);
    }

    return usernames;
  }

  /// Émet un événement de début de frappe
  void startTyping(String conversationId) {
    _webSocketService.emitTypingStart(conversationId);
  }

  /// Émet un événement de fin de frappe
  void stopTyping(String conversationId) {
    _webSocketService.emitTypingStop(conversationId);
  }

  /// Appelle GET /conversations
  /// SÉCURITÉ: S'abonne automatiquement à toutes les conversations auxquelles l'utilisateur a accès
  /// pour recevoir TOUS les événements (messages, typing, read receipts, etc.) même sans ouvrir la conversation
  ///
  /// Événements reçus via ces abonnements :
  /// - message:new (nouveaux messages)
  /// - typing:start/stop (indicateurs de frappe)
  /// - conv:read (messages lus)
  /// - presence:conversation (présence dans les conversations)
  Future<void> fetchConversations({bool forceRefresh = false}) async {
    try {
      // ✅ OPTIMISATION: Vérifier si déjà chargé récemment
      final now = DateTime.now();
      if (!forceRefresh &&
          _conversationsLoaded &&
          _lastConversationsLoad != null &&
          now.difference(_lastConversationsLoad!) <
              _conversationsCacheDuration) {
        debugPrint(
          '📡 [ConversationProvider] Conversations déjà chargées récemment, skip',
        );
        return;
      }

      _conversations = await _apiService.fetchConversations();

      // ✅ OPTIMISÉ: Vérifier les abonnements existants avant de s'abonner
      // SÉCURITÉ: Le backend vérifie les permissions dans conv:subscribe avant d'autoriser l'abonnement
      final alreadySubscribed = _webSocketService.subscribedConversations;
      final conversationsToSubscribe =
          _conversations
              .where((conv) => !alreadySubscribed.contains(conv.conversationId))
              .map((conv) => conv.conversationId)
              .toList();

      if (conversationsToSubscribe.isEmpty) {
        debugPrint(
          '📡 [ConversationProvider] Toutes les conversations sont déjà abonnées',
        );
      } else if (conversationsToSubscribe.length > 5) {
        // ✅ OPTIMISÉ: Utiliser batch subscription pour les grandes listes
        debugPrint(
          '📡 [ConversationProvider] Abonnement batch à ${conversationsToSubscribe.length} conversations',
        );
        try {
          final result = await _webSocketService.subscribeConversationsBatch(
            conversationsToSubscribe,
          );
          final subscribed = result['subscribed'] as int? ?? 0;
          final alreadySubscribedCount =
              result['alreadySubscribed'] as int? ?? 0;
          final unauthorized = result['unauthorized'] as int? ?? 0;
          debugPrint(
            '✅ [ConversationProvider] Batch subscription: $subscribed conversations abonnées, $alreadySubscribedCount déjà abonnées, $unauthorized non autorisées',
          );
        } catch (e) {
          debugPrint(
            '❌ [ConversationProvider] Erreur batch subscription, fallback individuel: $e',
          );
          // Fallback: abonner une par une
          for (final convId in conversationsToSubscribe) {
            subscribe(convId);
          }
        }
      } else {
        // Pour peu de conversations, abonner une par une
        debugPrint(
          '📡 [ConversationProvider] Abonnement individuel à ${conversationsToSubscribe.length} conversations',
        );
        for (final convId in conversationsToSubscribe) {
          subscribe(convId);
        }
      }

      debugPrint(
        '📡 [ConversationProvider] Événements qui seront reçus: message:new, typing:start/stop, conv:read, presence:conversation',
      );

      // ✅ OPTIMISATION: Mettre à jour les flags
      _conversationsLoaded = true;
      _lastConversationsLoad = now;

      // 🚀 OPTIMISATION: Notification immédiate pour l'affichage initial (critique)
      _notifyListenersImmediate();
    } catch (e) {
      debugPrint('❌ fetchConversations error: $e');
      rethrow;
    }
  }

  /// ✅ NOUVEAU: Méthode pour forcer le rechargement
  Future<void> refreshConversations() async {
    await fetchConversations(forceRefresh: true);
  }

  /// Appelle POST /conversations
  Future<String> createConversation(
    String groupId,
    List<String> memberIds,
    String type,
  ) => _apiService.createConversation(
    groupId: groupId,
    memberIds: memberIds,
    type: type,
  );

  /// Appelle GET /conversations/:id et met à jour la liste.
  /// 🚀 OPTIMISATION: Utilise fetchConversationDetailRaw pour éviter 2 appels API
  Future<Conversation> fetchConversationDetail(
    BuildContext context,
    String conversationId,
  ) async {
    try {
      // 🚀 OPTIMISATION: Utiliser seulement fetchConversationDetailRaw pour éviter 2 appels API
      final rawResponse = await _apiService.fetchConversationDetailRaw(
        conversationId,
      );

      // Extraire les informations des membres depuis la réponse brute
      if (rawResponse['members'] != null) {
        final members = rawResponse['members'] as List<dynamic>;
        for (final member in members) {
          final memberMap = member as Map<String, dynamic>;
          final userId = memberMap['userId'] as String;
          final username = memberMap['username'] as String;
          _userUsernames[userId] = username;
          debugPrint('👤 [Usernames] Cached username for $userId: $username');
        }
      }

      // Construire l'objet Conversation depuis la réponse brute (évite un 2ème appel API)
      final convo = Conversation.fromJson(rawResponse);

      final idx = _conversations.indexWhere(
        (c) => c.conversationId == conversationId,
      );
      if (idx >= 0) {
        _conversations[idx] = convo;
      } else {
        _conversations.add(convo);
      }
      // 🚀 OPTIMISATION: Notification immédiate pour nouvelle conversation (critique)
      _notifyListenersImmediate();
      return convo;
    } on RateLimitException {
      if (context.mounted) {
        SnackbarService.showRateLimitError(context);
      }
      rethrow;
    } catch (e) {
      debugPrint('❌ fetchConversationDetail error: $e');
      if (context.mounted) {
        SnackbarService.showError(
          context,
          'Impossible de charger la conversation : $e',
        );
      }
      rethrow;
    }
  }

  /// Appelle GET /conversations/:id/messages avec pagination (chargement initial)
  /// Retourne true s'il y a encore des messages à charger, false sinon
  Future<bool> _fetchMessagesWithHasMore(
    BuildContext context,
    String conversationId, {
    int limit = 20, // Charger seulement les 20 derniers messages
    String? cursor,
  }) async {
    try {
      final items = await _apiService.fetchMessagesV2(
        conversationId: conversationId,
        limit: limit,
        cursor: cursor,
      );
      final List<Message> display =
          items.map((it) {
            final senderUserId = (it.sender['userId'] as String?) ?? '';

            // CORRECTION: Préserver les données existantes si le message existe déjà
            Message? existingMessage;
            try {
              existingMessage = _messages[conversationId]?.firstWhere(
                (msg) => msg.id == it.messageId,
              );
            } catch (e) {
              existingMessage = null;
            }

            // Ne jamais rattacher la preuve et le texte d'une enveloppe déjà
            // authentifiée à une nouvelle enveloppe REST non vérifiée qui
            // réutiliserait le même identifiant.
            if (existingMessage?.signatureValid == true) {
              return existingMessage!;
            }

            final msg = Message(
              id: it.messageId,
              conversationId: conversationId,
              senderId: senderUserId,
              encrypted: null,
              iv: null,
              encryptedKeys: const {},
              signatureValid: false,
              senderPublicKey: null,
              timestamp: it.sentAt,
              v2Data: it.toJson(),
              decryptedText: null,
            );

            // 🚀 OPTIMISATION SIGNAL: Sauvegarder automatiquement chaque message reçu
            // CORRECTION: Ne pas sauvegarder immédiatement si signatureValid n'est pas encore vérifié
            // On sauvegardera après la vérification de signature dans decryptMessageIfNeeded
            // Cela évite de sauvegarder avec signatureValid: false puis de re-sauvegarder après
            // LocalMessageStorage.instance.saveMessage(msg).catchError((e) {
            //   debugPrint('⚠️ Erreur sauvegarde message local: $e');
            // });

            return msg;
          }).toList();

      // Trier les messages par timestamp (plus ancien en premier pour affichage chronologique)
      display.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // Pour le chargement initial, remplacer complètement mais préserver les textes déchiffrés
      if (cursor == null) {
        // Sauvegarder les textes déchiffrés existants
        final existingMessages = _messages[conversationId] ?? [];
        final decryptedTexts = <String, String>{};
        for (final msg in existingMessages) {
          if (msg.signatureValid == true && msg.decryptedText != null) {
            decryptedTexts[msg.id] = msg.decryptedText!;
          }
        }

        // Restaurer les textes déchiffrés dans les nouveaux messages
        for (final msg in display) {
          if (decryptedTexts.containsKey(msg.id)) {
            msg.decryptedText = decryptedTexts[msg.id];
            _decryptedCache[msg.id] = decryptedTexts[msg.id]!;
          } else if (msg.signatureValid == true &&
              _decryptedCache.containsKey(msg.id)) {
            // Restaurer depuis le cache mémoire (session courante)
            msg.decryptedText = _decryptedCache[msg.id];
          }
        }

        _messages[conversationId] = display;

        // 🚀 OPTIMISATION: Nettoyer les messages si la limite est dépassée
        _trimMessagesIfNeeded(conversationId);

        // CORRECTION: Sauvegarder les messages dans la DB après les avoir ajoutés
        // Cela permet de sauvegarder avec signatureValid: false initialement
        // puis de mettre à jour après la vérification de signature
        for (final msg in display) {
          LocalMessageStorage.instance.saveMessage(msg).catchError((e) {
            debugPrint('⚠️ Erreur sauvegarde message local: $e');
          });
        }
      } else {
        // Pour la pagination, ajouter au début (messages plus anciens)
        final existing = _messages[conversationId] ?? [];
        _messages[conversationId] = [...display, ...existing];
        // Re-trier après ajout (plus ancien en premier)
        _messages[conversationId]!.sort(
          (a, b) => a.timestamp.compareTo(b.timestamp),
        );

        // 🚀 OPTIMISATION: Nettoyer les messages si la limite est dépassée
        // Important: après pagination car on ajoute des messages anciens
        _trimMessagesIfNeeded(conversationId);

        // Sauvegarder les nouveaux messages
        for (final msg in display) {
          LocalMessageStorage.instance.saveMessage(msg).catchError((e) {
            debugPrint('⚠️ Erreur sauvegarde message local: $e');
          });
        }
      }

      // 🚀 OPTIMISATION: Batching pour éviter les freezes lors du chargement
      _notifyListenersBatched();

      // CORRECTION: Retourner s'il y a encore des messages à charger
      return items.isNotEmpty;
    } on RateLimitException {
      SnackbarService.showRateLimitError(context);
      return false;
    } catch (e) {
      debugPrint('❌ _fetchMessagesWithHasMore error: $e');

      // CORRECTION: Gérer spécifiquement les erreurs 500 du backend
      if (e.toString().contains('Erreur 500')) {
        debugPrint('🚨 Erreur serveur 500 - Problème côté backend');
        // Ne pas arrêter complètement le chargement, juste cette requête
        return false;
      }

      return false;
    }
  }

  /// Appelle GET /conversations/:id/messages avec pagination (chargement initial)
  /// 🚀 OPTIMISATION SIGNAL: Charge d'abord depuis le stockage local (instantané)
  /// puis synchronise avec le serveur en arrière-plan
  Future<void> fetchMessages(
    BuildContext context,
    String conversationId, {
    int limit = 20, // Charger seulement les 20 derniers messages
    String? cursor,
  }) async {
    // 📊 BENCHMARK: Mesurer le chargement initial complet
    return await PerformanceBenchmark.instance.measureAsync(
      cursor == null ? 'fetchMessages_initial' : 'fetchMessages_pagination',
      () async => _fetchMessagesImpl(
        context,
        conversationId,
        limit: limit,
        cursor: cursor,
      ),
    );
  }

  Future<void> _fetchMessagesImpl(
    BuildContext context,
    String conversationId, {
    int limit = 20,
    String? cursor,
  }) async {
    // 🚀 OPTIMISATION SIGNAL: Charger d'abord depuis le stockage local
    // UNIQUEMENT pour le chargement initial (pas pour la pagination)
    if (cursor == null) {
      try {
        // Initialiser le stockage local de manière non-bloquante
        // Si l'initialisation échoue, on continue avec le serveur
        try {
          await LocalMessageStorage.instance.initialize();
        } catch (initError) {
          debugPrint(
            '⚠️ Erreur initialisation stockage local (non-bloquant): $initError',
          );
          // Continuer avec le serveur même si l'init échoue
        }

        // Vérifier si le stockage local est disponible
        if (!LocalMessageStorage.instance.isAvailable) {
          debugPrint(
            '📭 Stockage local non disponible, chargement depuis le serveur',
          );
        } else {
          // 🚀 OPTIMISATION: Limiter strictement à 20 messages max pour éviter la surcharge
          // Même si limit est plus grand, on ne charge jamais plus que nécessaire
          final effectiveLimit =
              limit > 20 ? 20 : limit; // Limite de sécurité max 20
          debugPrint(
            '💾 Chargement des $effectiveLimit derniers messages depuis le stockage local...',
          );

          // 📊 BENCHMARK: Mesurer le chargement depuis la DB locale
          final localMessages = await PerformanceBenchmark.instance
              .measureAsync(
                'fetchMessages_load_local_db',
                () => LocalMessageStorage.instance.loadMessagesForConversation(
                  conversationId,
                  limit: effectiveLimit,
                ),
              );

          if (localMessages.isNotEmpty) {
            debugPrint(
              '⚡ ${localMessages.length} messages chargés depuis le stockage local (instantané)',
            );

            // 🚀 OPTIMISATION: Fusionner intelligemment avec les messages déjà en mémoire
            // Utiliser des Maps pour O(1) lookup au lieu de O(n) pour chaque message
            final existingMessages = _messages[conversationId] ?? [];
            final existingById = <String, Message>{};
            for (final msg in existingMessages) {
              existingById[msg.id] = msg;
            }

            // 🚀 OPTIMISATION: Créer un Set pour tracker les IDs déjà fusionnés (évite les doublons)
            final mergedIds = <String>{};
            final mergedMessages = <Message>[];

            // Étape 1: Traiter les messages locaux
            for (final localMsg in localMessages) {
              final existing = existingById[localMsg.id];
              if (existing != null) {
                // Message existe déjà en mémoire (ajouté via WebSocket)
                // Préserver signatureValid et decryptedText de la version mémoire
                mergedMessages.add(
                  Message(
                    id: existing.id,
                    conversationId: existing.conversationId,
                    senderId: existing.senderId,
                    encrypted: existing.encrypted,
                    iv: existing.iv,
                    encryptedKeys: existing.encryptedKeys,
                    signatureValid: existing.signatureValid,
                    senderPublicKey: existing.senderPublicKey,
                    timestamp: existing.timestamp,
                    v2Data: existing.v2Data ?? localMsg.v2Data,
                    decryptedText:
                        existing.signatureValid == true
                            ? existing.decryptedText
                            : null,
                  ),
                );
                mergedIds.add(existing.id);
              } else {
                // Nouveau message depuis la DB
                if (localMsg.signatureValid == true &&
                    _decryptedCache.containsKey(localMsg.id)) {
                  localMsg.decryptedText = _decryptedCache[localMsg.id];
                }
                mergedMessages.add(localMsg);
                mergedIds.add(localMsg.id);
              }
            }

            // Étape 2: Ajouter les messages en mémoire qui ne sont pas dans la DB (très récents)
            for (final existing in existingById.values) {
              if (!mergedIds.contains(existing.id)) {
                mergedMessages.add(existing);
              }
            }

            // 🚀 OPTIMISATION: Trier seulement si nécessaire (les messages locaux sont déjà triés)
            // On trie seulement si on a ajouté des messages en mémoire
            if (existingById.isNotEmpty) {
              mergedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
            }

            _messages[conversationId] = mergedMessages;

            // 🚀 OPTIMISATION: Nettoyer les messages si la limite est dépassée
            _trimMessagesIfNeeded(conversationId);

            // 🚀 OPTIMISATION: Notification immédiate pour l'affichage initial (critique)
            _notifyListenersImmediate();

            debugPrint(
              '✅ Messages locaux affichés immédiatement, synchronisation serveur en cours...',
            );

            // CORRECTION CRITIQUE: Toujours charger depuis le serveur pour récupérer les messages récents
            // même si on a des messages locaux (l'app peut avoir été fermée)
            // On charge les messages les plus récents (sans curseur) pour s'assurer de tout récupérer
            // IMPORTANT: Attendre la synchronisation pour s'assurer que le dernier message est inclus
            try {
              await _syncMessagesFromServer(
                context,
                conversationId,
                limit: limit,
                forceRecent: true,
              );
              debugPrint('✅ Synchronisation serveur terminée');
            } catch (e) {
              debugPrint('⚠️ Erreur synchronisation serveur: $e');
            }

            return; // Afficher immédiatement les messages locaux
          } else {
            debugPrint(
              '📭 Aucun message local trouvé pour $conversationId, chargement depuis le serveur',
            );
          }
        }
      } catch (e) {
        debugPrint('⚠️ Erreur chargement messages locaux: $e');
        // Fallback sur le serveur si erreur locale
      }
    }

    // 📊 BENCHMARK: Mesurer le chargement depuis le serveur
    await PerformanceBenchmark.instance.measureAsync(
      'fetchMessages_load_server',
      () => _fetchMessagesWithHasMore(
        context,
        conversationId,
        limit: limit,
        cursor: cursor,
      ),
    );
  }

  /// Synchronise les messages depuis le serveur en arrière-plan
  /// [forceRecent] : Si true, charge toujours les messages les plus récents (sans curseur)
  ///                 pour s'assurer de récupérer tous les messages même si l'app était fermée
  Future<void> _syncMessagesFromServer(
    BuildContext context,
    String conversationId, {
    int limit = 20,
    bool forceRecent = false,
  }) async {
    try {
      // Note: syncState non utilisé pour l'instant, mais peut être utile pour optimisations futures
      await LocalMessageStorage.instance.getSyncState(conversationId);

      int? cursorTimestamp;
      final messagesInMemory = _messages[conversationId];

      // CORRECTION CRITIQUE: Si forceRecent est true, ne pas utiliser de curseur
      // pour charger les messages les plus récents (cas où l'app était fermée)
      if (forceRecent) {
        debugPrint(
          '🔄 [Sync] Mode forceRecent: chargement des $limit messages les plus récents (sans curseur)',
        );
        cursorTimestamp = null;
      } else {
        // CORRECTION: Utiliser le timestamp du dernier message en mémoire (même s'il vient d'un autre device)
        // plutôt que le dernier message local, pour s'assurer de récupérer tous les messages
        // envoyés par d'autres devices du même compte
        if (messagesInMemory != null && messagesInMemory.isNotEmpty) {
          // Utiliser le timestamp du message le plus récent en mémoire
          final lastMessage = messagesInMemory.reduce(
            (a, b) => a.timestamp > b.timestamp ? a : b,
          );
          final lastTimestamp = lastMessage.timestamp;

          // CORRECTION: Vérifier si le dernier message est trop ancien (plus de 1 heure)
          // Si oui, charger les messages récents sans curseur pour s'assurer de tout récupérer
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final oneHourAgo = now - 3600;

          if (lastTimestamp < oneHourAgo) {
            debugPrint(
              '🔄 [Sync] Dernier message trop ancien (${now - lastTimestamp}s), chargement des messages récents',
            );
            cursorTimestamp = null;
          } else {
            cursorTimestamp = lastTimestamp;
            debugPrint(
              '🔄 [Sync] Utilisation du dernier message en mémoire: timestamp=$cursorTimestamp',
            );
          }
        } else {
          // Fallback: utiliser le dernier timestamp local
          final lastLocalTimestamp = await LocalMessageStorage.instance
              .getLastMessageTimestamp(conversationId);
          if (lastLocalTimestamp != null) {
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final oneHourAgo = now - 3600;

            if (lastLocalTimestamp < oneHourAgo) {
              debugPrint(
                '🔄 [Sync] Dernier message local trop ancien, chargement des messages récents',
              );
              cursorTimestamp = null;
            } else {
              cursorTimestamp = lastLocalTimestamp;
              debugPrint(
                '🔄 [Sync] Utilisation du dernier message local: timestamp=$cursorTimestamp',
              );
            }
          } else {
            debugPrint(
              '🔄 [Sync] Aucun message connu, chargement des $limit derniers messages',
            );
          }
        }
      }

      // Charger les nouveaux messages depuis le serveur
      // Si cursorTimestamp est null, on charge les messages les plus récents
      final items = await _apiService.fetchMessagesV2(
        conversationId: conversationId,
        limit: limit,
        cursor:
            cursorTimestamp != null
                ? (cursorTimestamp * 1000).toString()
                : null,
      );

      debugPrint(
        '🔄 [Sync] ${items.length} message(s) reçu(s) depuis le serveur',
      );

      if (items.isEmpty) {
        // Pas de nouveaux messages, mettre à jour l'état de sync
        await LocalMessageStorage.instance.updateSyncState(
          conversationId,
          DateTime.now().millisecondsSinceEpoch,
          lastMessageTimestamp: cursorTimestamp,
        );
        debugPrint('✅ Synchronisation serveur: aucun nouveau message');
        return;
      }

      // CORRECTION: Fusionner intelligemment avec les messages déjà en mémoire
      // au lieu de remplacer complètement
      final existingMessages = _messages[conversationId] ?? [];
      final existingById = <String, Message>{};
      for (final msg in existingMessages) {
        existingById[msg.id] = msg;
      }

      // Convertir les items serveur en Messages
      final newMessages = <Message>[];
      for (final item in items) {
        final senderUserId = (item.sender['userId'] as String?) ?? '';

        // Vérifier si le message existe déjà en mémoire
        final existing = existingById[item.messageId];
        if (existing?.signatureValid == true) {
          newMessages.add(existing!);
          continue;
        }

        final msg = Message(
          id: item.messageId,
          conversationId: conversationId,
          senderId: senderUserId,
          encrypted: null,
          iv: null,
          encryptedKeys: const {},
          signatureValid: false,
          senderPublicKey: null,
          timestamp: item.sentAt,
          v2Data: item.toJson(),
          decryptedText: null,
        );

        newMessages.add(msg);

        // Sauvegarder localement (non-bloquant)
        LocalMessageStorage.instance.saveMessage(msg).catchError((e) {
          debugPrint('⚠️ Erreur sauvegarde message local: $e');
        });
      }

      // 🚀 OPTIMISATION: Fusionner les nouveaux messages avec les existants de manière efficace
      // Utiliser un Set pour O(1) lookup au lieu de O(n) pour chaque message
      final newMessageIds = newMessages.map((m) => m.id).toSet();
      final mergedMessages = <Message>[];

      // Étape 1: Ajouter les messages existants qui ne sont pas dans les nouveaux (O(n))
      for (final existing in existingMessages) {
        if (!newMessageIds.contains(existing.id)) {
          mergedMessages.add(existing);
        }
      }

      // Étape 2: Ajouter les nouveaux messages
      mergedMessages.addAll(newMessages);

      // 🚀 OPTIMISATION: Trier seulement si nécessaire (si on a mélangé anciens et nouveaux)
      // Si tous les nouveaux messages sont plus récents que les existants, pas besoin de trier
      if (newMessages.isNotEmpty && existingMessages.isNotEmpty) {
        final oldestNew = newMessages
            .map((m) => m.timestamp)
            .reduce((a, b) => a < b ? a : b);
        final newestExisting = existingMessages
            .map((m) => m.timestamp)
            .reduce((a, b) => a > b ? a : b);
        // Si le plus ancien nouveau est plus récent que le plus récent existant, pas besoin de trier
        if (oldestNew < newestExisting) {
          mergedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
      }

      // Mettre à jour en mémoire seulement si la conversation est ouverte
      if (_messages.containsKey(conversationId)) {
        _messages[conversationId] = mergedMessages;

        // 🚀 OPTIMISATION: Nettoyer les messages si la limite est dépassée
        _trimMessagesIfNeeded(conversationId);

        // 🚀 OPTIMISATION: Batching pour la synchronisation en arrière-plan
        _notifyListenersBatched();
        debugPrint(
          '✅ Synchronisation serveur: ${items.length} nouveaux messages fusionnés',
        );
      }

      // Mettre à jour l'état de sync
      // CORRECTION: Utiliser le timestamp du message le plus récent (en mémoire ou nouveau)
      int? latestTimestamp;
      if (items.isNotEmpty) {
        latestTimestamp = items.first.sentAt;
      } else if (messagesInMemory != null && messagesInMemory.isNotEmpty) {
        final lastMessage = messagesInMemory.reduce(
          (a, b) => a.timestamp > b.timestamp ? a : b,
        );
        latestTimestamp = lastMessage.timestamp;
      } else {
        latestTimestamp = cursorTimestamp;
      }

      await LocalMessageStorage.instance.updateSyncState(
        conversationId,
        DateTime.now().millisecondsSinceEpoch,
        lastMessageTimestamp: latestTimestamp,
      );
    } catch (e) {
      debugPrint('❌ Erreur synchronisation serveur: $e');
    }
  }

  /// Charge les messages plus anciens (pagination vers le haut)
  /// Retourne true s'il y a encore des messages à charger, false sinon
  Future<bool> fetchOlderMessages(
    BuildContext context,
    String conversationId, {
    int limit = 20,
  }) async {
    // 📊 BENCHMARK: Mesurer la pagination (scroll)
    return await PerformanceBenchmark.instance.measureAsync(
      'fetchOlderMessages_scroll',
      () async =>
          _fetchOlderMessagesImpl(context, conversationId, limit: limit),
    );
  }

  Future<bool> _fetchOlderMessagesImpl(
    BuildContext context,
    String conversationId, {
    int limit = 20,
  }) async {
    final messages = _messages[conversationId] ?? [];
    if (messages.isEmpty) return false;

    // Utiliser le timestamp du message le plus ancien comme cursor
    final oldestMessage = messages.reduce(
      (a, b) => a.timestamp < b.timestamp ? a : b,
    );

    // CORRECTION: Le backend attend un timestamp en millisecondes pour new Date()
    // Vérifier que le timestamp est valide (pas dans le futur)
    final timestamp = oldestMessage.timestamp;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    debugPrint(
      '🔍 Debug timestamp - Message: ${oldestMessage.id}, Timestamp: $timestamp, Maintenant: $now',
    );

    if (timestamp > now) {
      debugPrint(
        '⚠️ Timestamp invalide détecté: $timestamp (maintenant: $now)',
      );
      debugPrint(
        '⚠️ Message problématique: ${oldestMessage.id}, Date: ${DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)}',
      );
      return false;
    }

    // Convertir en millisecondes pour le backend
    final cursorMs = timestamp * 1000;
    debugPrint(
      '🔄 Chargement messages anciens avec cursor: $cursorMs (timestamp ms)',
    );

    try {
      final hasMore = await _fetchMessagesWithHasMore(
        context,
        conversationId,
        limit: limit,
        cursor: cursorMs.toString(),
      );

      debugPrint('📄 Chargement terminé - hasMore: $hasMore');
      return hasMore;
    } catch (e) {
      debugPrint('❌ fetchOlderMessages error: $e');
      return false;
    }
  }

  Future<void> refreshReaders(String conversationId) async {
    try {
      final list = await _apiService.getConversationReaders(
        conversationId: conversationId,
      );
      _readersByConv[conversationId] = list;
      // 🚀 OPTIMISATION: Batching pour les mises à jour non-critiques
      _notifyListenersBatched();
    } catch (e) {
      debugPrint('❌ refreshReaders error: $e');
    }
  }

  /// Appelle GET /conversations/:id/messages?after=timestamp
  /// et ajoute les messages *nouveaux* au cache.
  Future<void> fetchMessagesAfter(
    BuildContext context,
    String conversationId,
    DateTime afterDateTime,
  ) async {
    try {
      final afterTs = afterDateTime.millisecondsSinceEpoch / 1000;
      final newMessages = await _apiService.fetchMessagesAfter(
        conversationId,
        afterTs + 1,
      );
      if (newMessages.isNotEmpty) {
        _messages.putIfAbsent(conversationId, () => []);
        _messages[conversationId]!.addAll(newMessages);
        // 🚀 OPTIMISATION: Batching pour les messages chargés en arrière-plan
        _notifyListenersBatched();

        // AJOUT: déchiffrer immédiatement les 3 derniers
        await decryptVisibleMessagesFast(conversationId, visibleCount: 3);
        // (Cette méthode notifie déjà à la fin)
      }
    } on RateLimitException {
      SnackbarService.showRateLimitError(context);
    } catch (e) {
      debugPrint('❌ fetchMessagesAfter error: $e');
    }
  }

  /// Appelle POST /messages puis ajoute localement
  Future<void> sendMessage(
    BuildContext context,
    String conversationId,
    String plaintext,
  ) async {
    try {
      debugPrint(
        '📤 [ConversationProvider] Début envoi message pour conversation $conversationId',
      );

      final myUserId = _authProvider.userId!;
      final myDeviceId = await _currentDeviceId();

      debugPrint(
        '📤 [ConversationProvider] myUserId: $myUserId, myDeviceId: $myDeviceId',
      );

      final groupId =
          _conversations
              .firstWhere((c) => c.conversationId == conversationId)
              .groupId;
      debugPrint('📤 [ConversationProvider] groupId: $groupId');

      // S'assurer que nos clés device sont générées
      await KeyManagerFinal.instance.ensureKeysFor(groupId, myDeviceId);

      // Vérifier et publier nos clés si nécessaire
      await _ensureMyDeviceKeysArePublished(groupId, myDeviceId);

      // CORRECTION: Récupérer seulement les devices des membres de la conversation
      // pour éviter l'erreur 403 (forbidden) si on inclut des devices de non-membres
      final conversationDetail = await _apiService.fetchConversationDetailRaw(
        conversationId,
      );
      final members = conversationDetail['members'] as List<dynamic>? ?? [];
      final memberUserIds = members.map((m) => m['userId'] as String).toList();

      // CORRECTION: Forcer un refresh du cache AVANT l'envoi pour s'assurer d'avoir tous les devices à jour
      // Cela garantit que tous les devices de l'expéditeur (y compris les autres appareils) sont inclus
      final allGroupDevices = await _keyDirectory.fetchGroupDevices(groupId);

      // Filtrer les devices pour ne garder que ceux des membres de la conversation
      var conversationDevices =
          allGroupDevices
              .where(
                (device) =>
                    memberUserIds.contains(device.userId) &&
                    device.status == 'active',
              )
              .toList();

      // CORRECTION CRITIQUE: Vérifier que notre propre device est bien dans la liste
      // Si ce n'est pas le cas, c'est que le cache n'est pas à jour, on force un refresh
      final myDeviceInList = conversationDevices.any(
        (d) => d.userId == myUserId && d.deviceId == myDeviceId,
      );
      if (!myDeviceInList) {
        // Attendre un peu pour que les clés soient propagées
        await Future.delayed(const Duration(milliseconds: 100));
        // Re-fetch depuis le serveur
        final refreshedDevices = await _keyDirectory.fetchGroupDevices(groupId);
        conversationDevices =
            refreshedDevices
                .where(
                  (device) =>
                      memberUserIds.contains(device.userId) &&
                      device.status == 'active',
                )
                .toList();
      }

      if (conversationDevices.isEmpty) {
        throw Exception(
          'Aucun device actif trouvé pour les membres de la conversation',
        );
      }

      debugPrint(
        '📤 [ConversationProvider] Chiffrement du message pour ${conversationDevices.length} devices',
      );
      final payload = await MessageCipherV2.encrypt(
        groupId: groupId,
        convId: conversationId,
        senderUserId: myUserId,
        senderDeviceId: myDeviceId,
        recipientsDevices: conversationDevices,
        plaintext: Uint8List.fromList(utf8.encode(plaintext)),
      );
      debugPrint(
        '📤 [ConversationProvider] Message chiffré, envoi au serveur...',
      );
      final result = await _apiService.sendMessageV2(payloadV2: payload);
      debugPrint(
        '📤 [ConversationProvider] Message envoyé avec succès: $result',
      );

      // CORRECTION CRITIQUE: Ajouter le message localement immédiatement après l'envoi réussi
      // L'expéditeur ne recevra pas le message via WebSocket (exclu par .except())
      // donc il faut l'ajouter manuellement pour un affichage immédiat
      try {
        final messageId = payload['messageId'] as String?;
        final sentAt = payload['sentAt'] as int?;

        if (messageId == null || sentAt == null) {
          debugPrint(
            '⚠️ [ConversationProvider] messageId ou sentAt manquant dans le payload: messageId=$messageId, sentAt=$sentAt',
          );
          return;
        }

        debugPrint(
          '📤 [ConversationProvider] Création du message local: messageId=$messageId, sentAt=$sentAt',
        );

        final sentMessage = Message(
          id: messageId,
          conversationId: conversationId,
          senderId: myUserId,
          encrypted: null,
          iv: null,
          encryptedKeys: const {},
          signatureValid: true, // On fait confiance à nos propres messages
          senderPublicKey: null,
          timestamp: sentAt,
          v2Data: payload,
          decryptedText: plaintext, // Texte en clair car c'est notre message
        );

        debugPrint(
          '📤 [ConversationProvider] Message créé, sauvegarde locale...',
        );

        // Sauvegarder localement
        await LocalMessageStorage.instance.saveMessage(sentMessage);
        debugPrint('📤 [ConversationProvider] Message sauvegardé localement');

        // Ajouter à la liste locale et notifier immédiatement
        addLocalMessage(sentMessage);
        debugPrint(
          '✅ [ConversationProvider] Message ajouté localement: $messageId',
        );
      } catch (e, stackTrace) {
        debugPrint(
          '❌ [ConversationProvider] Erreur lors de l\'ajout local du message: $e',
        );
        debugPrint('❌ [ConversationProvider] Stack trace: $stackTrace');
      }
    } on RateLimitException {
      SnackbarService.showRateLimitError(context);
      rethrow;
    } catch (e) {
      debugPrint(
        '❌ [ConversationProvider] Erreur lors de l\'envoi du message: $e',
      );
      debugPrint('❌ [ConversationProvider] Type d\'erreur: ${e.runtimeType}');

      // Si c'est une erreur de clés manquantes, essayer UNE SEULE FOIS
      if ((e.toString().contains('length=0') ||
              e.toString().contains('Failed assertion')) &&
          !plaintext.contains('🔧 RETRY:')) {
        try {
          // Tentative UNIQUE de publication automatique des clés
          final myDeviceId = await _currentDeviceId();
          final groupId =
              _conversations
                  .firstWhere((c) => c.conversationId == conversationId)
                  .groupId;
          await _ensureMyDeviceKeysArePublished(groupId, myDeviceId);

          // Retry une seule fois avec un marqueur pour éviter la boucle
          SnackbarService.showSuccess(
            context,
            'Clés publiées, nouvelle tentative',
          );
          await sendMessage(context, conversationId, '🔧 RETRY: $plaintext');
          return;
        } catch (retryError) {
          // Si le retry échoue aussi, afficher l'erreur originale
        }
      }

      SnackbarService.showError(
        context,
        'Impossible d\'envoyer le message : $e',
      );
      rethrow;
    }
  }

  /// CORRECTION: Synchronisation proactive des clés pour tous les groupes
  Future<void> ensureDeviceKeysForAllGroups() async {
    try {
      final myDeviceId = await _currentDeviceId();
      final conversations = _conversations;

      debugPrint(
        '🔑 Synchronisation proactive des clés pour ${conversations.length} conversations',
      );

      for (final conv in conversations) {
        try {
          await _ensureMyDeviceKeysArePublished(conv.groupId, myDeviceId);
        } catch (e) {
          debugPrint(
            '❌ Erreur synchronisation clés pour groupe ${conv.groupId}: $e',
          );
        }
      }

      debugPrint('✅ Synchronisation proactive terminée');
    } catch (e) {
      debugPrint('❌ Erreur synchronisation proactive: $e');
    }
  }

  /// S'assurer que les clés de notre device sont publiées pour le groupe
  Future<void> _ensureMyDeviceKeysArePublished(
    String groupId,
    String deviceId,
  ) async {
    try {
      // Vérifier si les clés ont été régénérées et doivent être republiées
      if (KeyManagerFinal.instance.keysNeedRepublishing) {
        debugPrint(
          '🔑 REPUBLICATION: Les clés ont été régénérées, republication nécessaire',
        );

        final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(
          groupId,
          deviceId,
        );
        final sigPub = pubKeys['pk_sig']!;
        final kemPub = pubKeys['pk_kem']!;

        await _apiService.publishGroupDeviceKey(
          groupId: groupId,
          deviceId: deviceId,
          pkSigB64: sigPub,
          pkKemB64: kemPub,
        );

        // Marquer que les clés ont été republiées
        KeyManagerFinal.instance.markKeysRepublished();

        // Invalider le cache pour que les nouvelles clés soient récupérées
        await _keyDirectory.fetchGroupDevices(
          groupId,
        ); // Force refresh du cache
        debugPrint('✅ Clés republiées et cache mis à jour');
        return;
      }

      // CORRECTION CRITIQUE: Vérifier aussi les devices révoqués avant de republier
      // pour éviter de réactiver un device révoqué
      final myUserId = _authProvider.userId;
      if (myUserId != null) {
        // Vérifier si le device est révoqué en utilisant l'endpoint my-devices
        try {
          final myDevices = await _apiService.fetchMyGroupDeviceKeys(groupId);
          final myDevice = myDevices.firstWhere(
            (d) => d['deviceId'] == deviceId && d['userId'] == myUserId,
            orElse: () => <String, dynamic>{},
          );

          if (myDevice.isNotEmpty) {
            final status = myDevice['status'] as String? ?? 'active';
            if (status == 'revoked') {
              debugPrint(
                '⚠️ Device $deviceId est révoqué, publication refusée',
              );
              return; // Ne pas republier un device révoqué
            }
          }
        } catch (e) {
          debugPrint('⚠️ Erreur vérification statut device: $e');
          // Continuer si l'endpoint n'est pas disponible (fallback)
        }
      }

      final recipients = await _keyDirectory.getGroupDevices(groupId);
      final myKeysInGroup =
          recipients.where((r) => r.deviceId == deviceId).toList();

      if (myKeysInGroup.isEmpty) {
        debugPrint(
          '🔑 Publication automatique des clés manquantes pour le groupe $groupId',
        );

        // S'assurer que les clés device sont générées
        await KeyManagerFinal.instance.ensureKeysFor(groupId, deviceId);

        final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(
          groupId,
          deviceId,
        );
        final sigPub = pubKeys['pk_sig']!;
        final kemPub = pubKeys['pk_kem']!;

        try {
          await _apiService.publishGroupDeviceKey(
            groupId: groupId,
            deviceId: deviceId,
            pkSigB64: sigPub,
            pkKemB64: kemPub,
          );

          // Invalider le cache pour que les nouvelles clés soient récupérées
          await _keyDirectory.fetchGroupDevices(
            groupId,
          ); // Force refresh du cache
          debugPrint('✅ Clés publiées et cache mis à jour');
        } catch (e) {
          // Si l'erreur est "device_revoked", c'est normal et on ne doit pas la propager
          if (e.toString().contains('device_revoked') ||
              e.toString().contains('403')) {
            debugPrint('⚠️ Publication refusée: device révoqué');
            return;
          }
          rethrow;
        }
      }
    } catch (e) {
      debugPrint('❌ Erreur publication automatique clés: $e');
      rethrow;
    }
  }

  /// S’abonne ou se désabonne au WS
  void subscribe(String conversationId) {
    debugPrint(
      '📡 [ConversationProvider] Abonnement demandé pour conversation: $conversationId',
    );
    _webSocketService.subscribeConversation(conversationId);
  }

  void unsubscribe(String conversationId) => _webSocketService
      .unsubscribeConversation(conversationId, userId: _authProvider.userId);

  /// Ajoute un message *localement* (WS ou REST) et notifie.
  void addLocalMessage(Message message) {
    final convId = message.conversationId;
    _messages.putIfAbsent(convId, () => []);

    // CORRECTION: Vérifier si le message existe déjà pour éviter les doublons
    final existingIndex = _messages[convId]!.indexWhere(
      (m) => m.id == message.id,
    );
    if (existingIndex >= 0) {
      // Message existe déjà : mettre à jour avec la nouvelle version (préserver signatureValid si déjà vérifié)
      final existing = _messages[convId]![existingIndex];
      // Une enveloppe brute portant le même ID ne doit jamais hériter de la
      // preuve associée à l'enveloppe existante.
      if (existing.signatureValid == true && message.signatureValid != true) {
        _messages[convId]![existingIndex] = existing;
      } else {
        _messages[convId]![existingIndex] = message;
      }
    } else {
      // Nouveau message : l'ajouter
      _messages[convId]!.add(message);
      // Trier par timestamp pour maintenir l'ordre chronologique
      _messages[convId]!.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // 🚀 OPTIMISATION: Nettoyer les messages si la limite est dépassée
      // (seulement pour les nouveaux messages, pas pour les mises à jour)
      _trimMessagesIfNeeded(convId);
    }

    // 🚀 OPTIMISATION: Notification immédiate pour les nouveaux messages (critique)
    // Les messages WebSocket doivent être affichés immédiatement
    _notifyListenersImmediate();
  }

  // ─── Handlers internes pour les événements WS ──────────────────────────────

  /// Récupère les nouveaux messages depuis le serveur et les ajoute à la conversation
  /// Utilisé quand un ping WebSocket est reçu et que l'utilisateur est dans la conversation
  Future<void> _fetchNewMessageFromServer(String conversationId) async {
    try {
      // CORRECTION: Récupérer les messages les plus récents SANS cursor
      // Le backend utilise "sent_at < cursor", donc pour récupérer les nouveaux messages,
      // on doit récupérer les N derniers messages et filtrer ceux déjà présents
      final items = await _apiService.fetchMessagesV2(
        conversationId: conversationId,
        limit:
            20, // Récupérer les 20 derniers messages pour s'assurer de ne rien manquer
        cursor: null, // Pas de cursor pour obtenir les plus récents
      );

      if (items.isEmpty) {
        debugPrint(
          '🔔 [ConversationProvider] Aucun nouveau message trouvé pour $conversationId',
        );
        return;
      }

      debugPrint(
        '🔔 [ConversationProvider] ${items.length} nouveau(x) message(s) récupéré(s) pour $conversationId',
      );

      // Traiter et ajouter les nouveaux messages
      final myUserId = _authProvider.userId;
      if (myUserId == null) {
        debugPrint(
          '⚠️ [ConversationProvider] myUserId est null, impossible de traiter les messages',
        );
        return;
      }
      final myDeviceId = await _currentDeviceId();

      // Récupérer le groupId depuis la conversation
      final conversation = _conversations.firstWhere(
        (c) => c.conversationId == conversationId,
        orElse:
            () => throw Exception('Conversation $conversationId introuvable'),
      );
      final groupId = conversation.groupId;

      final existingMessages = _messages[conversationId] ?? [];
      final existingMessageIds = existingMessages.map((m) => m.id).toSet();
      final lastTimestamp =
          existingMessages.isNotEmpty
              ? existingMessages
                  .map((m) => m.timestamp)
                  .reduce((a, b) => a > b ? a : b)
              : 0;
      debugPrint(
        '🔔 [ConversationProvider] Messages existants en mémoire: ${existingMessages.length}, dernier timestamp: $lastTimestamp',
      );

      // Traiter chaque nouveau message
      int addedCount = 0;
      int skippedCount = 0;
      int errorCount = 0;
      for (final item in items) {
        // Vérifier si le message existe déjà
        if (existingMessageIds.contains(item.messageId)) {
          skippedCount++;
          debugPrint(
            '⏭️ [ConversationProvider] Message ${item.messageId} déjà présent, ignoré',
          );
          continue; // Message déjà présent, passer au suivant
        }

        // Vérifier si le message est plus récent que le dernier message en mémoire
        if (item.sentAt <= lastTimestamp) {
          skippedCount++;
          debugPrint(
            '⏭️ [ConversationProvider] Message ${item.messageId} plus ancien que le dernier (${item.sentAt} <= $lastTimestamp), ignoré',
          );
          continue;
        }

        // Déchiffrer le message
        try {
          final fastResult = await MessageCipherV2.decryptFast(
            groupId: groupId,
            expectedConversationId: conversationId,
            myUserId: myUserId,
            myDeviceId: myDeviceId,
            messageV2: item.toJson(),
            keyDirectory: _keyDirectory,
            priority: 1, // Haute priorité pour les nouveaux messages
          );

          final decryptedText = utf8.decode(
            fastResult['decryptedText'] as Uint8List,
          );
          final senderUserId = (item.sender['userId'] as String?) ?? '';

          // Créer le message
          final msg = Message(
            id: item.messageId,
            conversationId: conversationId,
            senderId: senderUserId,
            encrypted: null,
            iv: null,
            encryptedKeys: const {},
            signatureValid: true,
            senderPublicKey: null,
            timestamp: item.sentAt,
            v2Data: item.toJson(),
            decryptedText: decryptedText,
          );

          // Sauvegarder localement (non-bloquant)
          LocalMessageStorage.instance.saveMessage(msg).catchError((saveError) {
            debugPrint(
              '⚠️ Erreur sauvegarde message local (non-bloquant): $saveError',
            );
          });

          // Mettre en cache mémoire
          _decryptedCache[item.messageId] = decryptedText;

          // Ajouter le message et notifier immédiatement
          addLocalMessage(msg);
          addedCount++;
          debugPrint(
            '✅ [ConversationProvider] Message ${item.messageId} ajouté avec succès (timestamp: ${item.sentAt})',
          );
        } on MessageAuthenticationException catch (error) {
          errorCount++;
          debugPrint('Message REST rejeté: ${error.code}');
        } catch (_) {
          errorCount++;
          debugPrint('Message REST impossible à traiter');
        }
      }

      debugPrint(
        '🔔 [ConversationProvider] Résumé: ${addedCount} message(s) ajouté(s), ${skippedCount} ignoré(s), ${errorCount} erreur(s) sur ${items.length} récupéré(s)',
      );
    } catch (e, stackTrace) {
      debugPrint(
        '❌ [ConversationProvider] Erreur lors de la récupération des nouveaux messages: $e',
      );
      debugPrint('❌ [ConversationProvider] Stack trace: $stackTrace');
    }
  }

  void _onWebSocketNewMessageV2(Map<String, dynamic> payload) async {
    try {
      debugPrint('📨 [ConversationProvider] _onWebSocketNewMessageV2 appelé');
      debugPrint(
        '📨 [ConversationProvider] Payload reçu: ${payload.keys.join(", ")}',
      );

      final type = payload['type'] as String?;
      final groupId = payload['groupId'] as String?;
      final messageId = payload['messageId'] as String?;
      final convId = payload['convId'] as String?;
      final senderData = payload['sender'];

      // CORRECTION: Vérifier si le payload contient les données complètes du message
      // Si messageId et sender sont présents, c'est un payload complet, sinon c'est un ping minimal
      final hasCompletePayload =
          messageId != null && senderData != null && senderData is Map;

      if (type == 'message:new' && !hasCompletePayload) {
        // Ping minimal (seulement convId et groupId, pas de données sensibles)
        if (convId != null) {
          var trustedGroupId = groupIdForConversation(convId);
          if (trustedGroupId == null) {
            await fetchConversations();
            trustedGroupId = groupIdForConversation(convId);
          }
          if (trustedGroupId == null) {
            debugPrint('Ping WebSocket ignoré: conversation locale inconnue');
            return;
          }

          // Vérifier si l'utilisateur est déjà dans cette conversation
          final tracker = NavigationTrackerService();
          final isInThisConversation = tracker.isInConversation(convId);

          if (!isInThisConversation) {
            final badgeService = NotificationBadgeService();
            badgeService.markConversationAsNew(convId, groupId: trustedGroupId);
            debugPrint(
              '🔔 [ConversationProvider] Conversation $convId marquée comme nouvelle (ping reçu)',
            );
          } else {
            // Récupérer le nouveau message depuis le serveur quand l'utilisateur est dans la conversation
            debugPrint(
              '🔔 [ConversationProvider] Ping reçu pour conversation active $convId, récupération du nouveau message...',
            );
            _fetchNewMessageFromServer(convId).catchError((e) {
              debugPrint(
                '❌ [ConversationProvider] Erreur lors de la récupération du nouveau message: $e',
              );
            });
          }
        } else {
          // Fallback: si les identifiants ne sont pas présents, rafraîchir toutes les conversations
          debugPrint(
            '⚠️ [ConversationProvider] Ping reçu sans convId/groupId, rafraîchissement de toutes les conversations',
          );
          final tracker = NavigationTrackerService();
          if (!tracker.isInAnyConversation()) {
            await fetchConversations();
            final badgeService = NotificationBadgeService();
            for (final conv in _conversations) {
              badgeService.markConversationAsNew(
                conv.conversationId,
                groupId: conv.groupId,
              );
            }
          }
        }

        notifyListeners();
        return;
      }

      // Payload complet avec toutes les données du message (format normal)
      if (groupId == null || messageId == null || convId == null) {
        debugPrint(
          '⚠️ [ConversationProvider] Données manquantes dans le payload: groupId=$groupId, messageId=$messageId, convId=$convId',
        );
        return;
      }

      if (senderData == null || senderData is! Map) {
        debugPrint('⚠️ [ConversationProvider] Payload sender invalide');
        return;
      }

      final myUserId = _authProvider.userId;
      if (myUserId == null) {
        debugPrint(
          '⚠️ [ConversationProvider] myUserId est null, impossible de traiter le message',
        );
        return;
      }
      final myDeviceId = await _currentDeviceId();
      final trustedGroupId = groupIdForConversation(convId);
      if (trustedGroupId == null) {
        debugPrint('Message WebSocket rejeté: conversation inconnue');
        return;
      }

      debugPrint(
        '📨 [ConversationProvider] Message reçu: convId=$convId, messageId=$messageId, groupId=$groupId',
      );

      // Extraire le senderId avec vérification
      final senderId = senderData['userId'] as String?;
      if (senderId == null) {
        debugPrint(
          '⚠️ [ConversationProvider] senderId est null dans le payload',
        );
        return;
      }

      debugPrint('🔍 [ConversationProvider] Comparaison senderId:');
      debugPrint('🔍 [ConversationProvider]   senderId du message: $senderId');
      debugPrint('🔍 [ConversationProvider]   myUserId: $myUserId');
      debugPrint(
        '🔍 [ConversationProvider]   Sont-ils égaux? ${senderId == myUserId}',
      );

      // 🚀 OPTIMISATION: Utiliser decryptFast() avec priorité haute pour affichage immédiat
      // Les nouveaux messages WebSocket doivent apparaître instantanément
      final fastResult = await MessageCipherV2.decryptFast(
        groupId: trustedGroupId,
        expectedConversationId: convId,
        myUserId: myUserId,
        myDeviceId: myDeviceId,
        messageV2: payload,
        keyDirectory: _keyDirectory,
        priority: 1, // Haute priorité pour les nouveaux messages
      );

      final decryptedText = utf8.decode(
        fastResult['decryptedText'] as Uint8List,
      );

      // Incrémenter le compteur de messages non lus si ce n'est pas notre message
      if (senderId != myUserId) {
        _unreadCounts[convId] = (_unreadCounts[convId] ?? 0) + 1;

        // ✅ CORRECTION: Marquer le badge AVANT d'afficher la notification
        final badgeService = NotificationBadgeService();
        badgeService.markConversationAsNew(convId, groupId: trustedGroupId);
        debugPrint(
          '🔔 [ConversationProvider] Badge marqué pour conversation $convId (groupe $groupId)',
        );

        // 🚀 OPTIMISATION: Batching pour les compteurs (non-critique)
        _notifyListenersBatched();

        // Afficher une notification si l'utilisateur n'est pas dans cette conversation
        debugPrint(
          '🔔 [ConversationProvider] Nouveau message reçu dans conversation $convId',
        );

        final tracker = NavigationTrackerService();
        final isInConv = tracker.isInConversation(convId);
        final currentScreen = tracker.currentScreen;
        debugPrint(
          '🔔 [ConversationProvider] Utilisateur dans conversation: $isInConv, Écran actuel: $currentScreen',
        );

        await _showNotificationIfNeeded(convId, senderId, decryptedText);
      } else {
        debugPrint(
          '🔔 [ConversationProvider] Message ignoré (envoyé par nous-même)',
        );
      }

      // Création du message avec texte déchiffré
      final msg = Message(
        id: messageId,
        conversationId: convId,
        senderId: senderId,
        encrypted: null,
        iv: null,
        encryptedKeys: const {},
        signatureValid: true,
        senderPublicKey: null,
        timestamp: (payload['sentAt'] as num).toInt(),
        v2Data: payload, // Stocker les données V2 pour cohérence
        decryptedText: decryptedText,
      );

      // 🚀 OPTIMISATION SIGNAL: Sauvegarder le message chiffré localement (non-bloquant)
      LocalMessageStorage.instance.saveMessage(msg).catchError((saveError) {
        debugPrint(
          '⚠️ Erreur sauvegarde message local (non-bloquant): $saveError',
        );
      });

      // Mettre en cache mémoire uniquement (session courante)
      _decryptedCache[messageId] = decryptedText;

      // Ajouter le message et notifier immédiatement pour affichage instantané
      addLocalMessage(msg);
    } on MessageAuthenticationException catch (error) {
      // Un événement forgé ou non authentifiable ne produit ni bulle,
      // ni cache, ni notification.
      debugPrint('Message WebSocket rejeté: ${error.code}');
    } catch (_) {
      debugPrint('Message WebSocket impossible à traiter');
    }
  }

  void _onWebSocketUserAdded(String conversationId, String userId) {
    fetchConversations();
  }

  void _onWebSocketConversationJoined() {
    fetchConversations();
  }

  void _onWebSocketGroupCreated(String? groupId, String? creatorId) {
    // SÉCURITÉ: Les paramètres peuvent être null si c'est un ping minimal
    if (groupId == null || creatorId == null) {
      debugPrint(
        '🏗️ [ConversationProvider] Ping reçu pour nouveau groupe (pas de données sensibles)',
      );
      return;
    }

    debugPrint(
      '🏗️ [ConversationProvider] Nouveau groupe créé: $groupId par $creatorId',
    );
    // CORRECTION: Rafraîchir la liste des groupes via le GroupProvider
    // Note: Le GroupProvider sera notifié via son propre callback WebSocket
    // On ne fait rien ici car c'est le GroupProvider qui gère les groupes
  }

  void _onWebSocketConversationCreated(
    String? convId,
    String? groupId,
    String? creatorId,
  ) {
    // CORRECTION: Le ping contient maintenant convId et groupId pour identifier précisément la conversation
    if (convId == null || groupId == null) {
      debugPrint(
        '⚠️ [ConversationProvider] Ping reçu pour nouvelle conversation sans convId/groupId',
      );
      // Fallback: rafraîchir toutes les conversations
      fetchConversations().then((_) {
        final badgeService = NotificationBadgeService();
        final myUserId = _authProvider.userId;
        for (final conv in _conversations) {
          // Ne pas marquer comme nouvelle si c'est l'utilisateur actuel qui l'a créée
          if (conv.creatorId != myUserId) {
            badgeService.markNewConversation(conv.conversationId, conv.groupId);
          }
        }
      });
      return;
    }

    debugPrint(
      '💬 [ConversationProvider] Nouvelle conversation créée: $convId dans $groupId par $creatorId',
    );

    // CORRECTION: Ne pas marquer comme nouvelle si c'est l'utilisateur actuel qui a créé la conversation
    final myUserId = _authProvider.userId;
    if (creatorId != null && creatorId == myUserId) {
      debugPrint(
        '🔔 [ConversationProvider] Conversation créée par l\'utilisateur actuel, pas de notification',
      );
      // Rafraîchir quand même la liste des conversations pour l'afficher
      fetchConversations().then((_) {
        notifyListeners();
      });
      return;
    }

    // Marquer seulement la nouvelle conversation comme nouvelle dans le badge service
    final badgeService = NotificationBadgeService();
    badgeService.markNewConversation(convId, groupId);

    // CORRECTION: Rafraîchir immédiatement la liste des conversations
    // Ne plus ajouter de notification texte - les badges suffisent
    fetchConversations()
        .then((_) {
          debugPrint(
            '🔔 [ConversationProvider] Nouvelle conversation $convId dans groupe $groupId (badge uniquement)',
          );
          notifyListeners();
        })
        .catchError((e) {
          debugPrint(
            '❌ [ConversationProvider] Erreur lors du fetch des conversations: $e',
          );
        });
  }

  // Presence + read receipts hooks (UI can observe derived state later)
  // Les méthodes _onPresenceUpdate et _onPresenceConversation sont maintenant gérées par GlobalPresenceService

  /// ✅ NOUVEAU: Gère les événements de présence batch
  void _onPresenceConversationBatch(
    String conversationId,
    List<Map<String, dynamic>> presences,
  ) {
    debugPrint(
      '👥 [ConversationProvider] Batch presence reçu pour $conversationId: ${presences.length} utilisateurs',
    );

    // Mettre à jour la présence pour tous les utilisateurs en une fois
    if (_conversationPresence[conversationId] == null) {
      _conversationPresence[conversationId] = {};
    }

    for (final presence in presences) {
      final userId = presence['userId'] as String?;
      final online = presence['online'] as bool? ?? false;

      if (userId != null) {
        _conversationPresence[conversationId]![userId] = online;
        // Mettre à jour aussi la présence globale
        _userOnline[userId] = online;
      }
    }

    // Synchroniser avec le service global de présence
    _syncWithGlobalPresence();

    // 🚀 OPTIMISATION: Batching pour les mises à jour de présence (non-critique)
    _notifyListenersBatched();
  }

  void _onConvRead(String convId, String userId, String at) {
    // Refresh readers to fetch usernames and timestamps
    // ignore: discarded_futures
    refreshReaders(convId);
  }

  // Handlers pour les indicateurs de frappe
  void _onTypingStart(String convId, String userId) {
    _typingUsers.putIfAbsent(convId, () => <String>{});
    _typingUsers[convId]!.add(userId);
    // 🚀 OPTIMISATION: Batching pour les indicateurs de frappe (non-critique)
    _notifyListenersBatched();
  }

  void _onTypingStop(String convId, String userId) {
    _typingUsers[convId]?.remove(userId);
    // 🚀 OPTIMISATION: Batching pour les indicateurs de frappe (non-critique)
    _notifyListenersBatched();
  }

  /// Affiche une notification si nécessaire (push + in-app)
  Future<void> _showNotificationIfNeeded(
    String conversationId,
    String senderId,
    String messageText,
  ) async {
    try {
      debugPrint('🔔 [ConversationProvider] _showNotificationIfNeeded appelé');
      debugPrint(
        '🔔 [ConversationProvider] conversationId: $conversationId, senderId: $senderId',
      );

      final tracker = NavigationTrackerService();

      // Vérifier si l'utilisateur est actuellement dans cette conversation
      final isInCurrentConversation = tracker.isInConversation(conversationId);
      final currentScreen = tracker.currentScreen;

      debugPrint(
        '🔔 [ConversationProvider] isInCurrentConversation: $isInCurrentConversation',
      );
      debugPrint('🔔 [ConversationProvider] currentScreen: $currentScreen');

      if (!isInCurrentConversation) {
        debugPrint(
          '🔔 [ConversationProvider] ✅ Utilisateur n\'est PAS dans la conversation, création de notification',
        );

        // Obtenir le nom de l'expéditeur
        final senderName = await _getSenderName(senderId);
        debugPrint('🔔 [ConversationProvider] senderName: $senderName');

        // Tronquer le message pour la notification
        final truncatedMessage =
            messageText.length > 50
                ? '${messageText.substring(0, 50)}...'
                : messageText;

        // Afficher une notification push (si l'app est en arrière-plan)
        await NotificationService.showMessageNotification(
          title: senderName.isNotEmpty ? senderName : 'Nouveau message',
          body: truncatedMessage,
          conversationId: conversationId,
          senderName: senderName,
        );
        debugPrint('🔔 [ConversationProvider] Notification push affichée');

        // Afficher une notification in-app si l'utilisateur est dans l'app mais pas sur la bonne conversation
        // Note: On ne peut pas utiliser BuildContext ici, donc on stocke les infos pour que l'UI les affiche
        // L'UI écoutera les changements et affichera les notifications
        _pendingInAppNotifications.add({
          'type': 'new_message',
          'conversationId': conversationId,
          'senderName': senderName,
          'messageText': truncatedMessage,
        });

        debugPrint(
          '🔔 [ConversationProvider] ✅ Notification in-app ajoutée pour la conversation $conversationId',
        );
        debugPrint(
          '🔔 [ConversationProvider] Total notifications en attente: ${_pendingInAppNotifications.length}',
        );

        // Notifier les listeners IMMÉDIATEMENT pour que l'UI puisse afficher la notification
        // Utiliser notifyListeners() au lieu de _notifyListenersBatched() pour les notifications
        notifyListeners();
        debugPrint('🔔 [ConversationProvider] ✅ Listeners notifiés');
      } else {
        debugPrint(
          '🔔 [ConversationProvider] ⏭️ Utilisateur est dans la conversation, pas de notification',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('❌ [ConversationProvider] Erreur affichage notification: $e');
      debugPrint('❌ [ConversationProvider] Stack trace: $stackTrace');
    }
  }

  /// Liste des notifications in-app en attente d'affichage
  final List<Map<String, dynamic>> _pendingInAppNotifications = [];

  /// Obtient et supprime les notifications in-app en attente
  List<Map<String, dynamic>> getPendingInAppNotifications() {
    final notifications = List<Map<String, dynamic>>.from(
      _pendingInAppNotifications,
    );
    if (notifications.isNotEmpty) {
      debugPrint(
        '🔔 [ConversationProvider] Récupération de ${notifications.length} notification(s) en attente',
      );
    }
    _pendingInAppNotifications.clear();
    return notifications;
  }

  /// Obtient le nom d'un utilisateur par son ID
  Future<String> _getSenderName(String userId) async {
    try {
      // Utiliser le cache des usernames si disponible
      if (_userUsernames.containsKey(userId)) {
        final username = _userUsernames[userId]!;
        debugPrint(
          '👤 [ConversationProvider] Username trouvé dans cache: $username',
        );
        return username;
      }

      // Chercher dans les conversations pour trouver le nom
      for (final conversation in _conversations) {
        // Essayer de récupérer les détails de la conversation pour obtenir les membres
        try {
          final detail = await _apiService.fetchConversationDetailRaw(
            conversation.conversationId,
          );
          if (detail['members'] != null) {
            final members = detail['members'] as List<dynamic>;
            for (final member in members) {
              final memberMap = member as Map<String, dynamic>;
              final memberUserId = memberMap['userId'] as String;
              final username = memberMap['username'] as String;
              _userUsernames[memberUserId] = username;

              if (memberUserId == userId) {
                debugPrint(
                  '👤 [ConversationProvider] Username trouvé: $username',
                );
                return username;
              }
            }
          }
        } catch (e) {
          // Ignorer les erreurs et continuer
        }
      }
    } catch (e) {
      debugPrint('❌ Erreur récupération nom expéditeur: $e');
    }

    // Fallback: utiliser l'ID tronqué
    final fallback =
        userId.length > 8 ? '${userId.substring(0, 8)}...' : userId;
    debugPrint(
      '👤 [ConversationProvider] Username non trouvé, utilisation fallback: $fallback',
    );
    return fallback;
  }
}
