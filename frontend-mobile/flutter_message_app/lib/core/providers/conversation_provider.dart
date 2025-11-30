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
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'package:flutter_message_app/core/services/notification_service.dart';
import 'package:flutter_message_app/core/services/global_presence_service.dart';
import 'package:flutter_message_app/core/services/local_message_storage.dart';
import 'package:flutter_message_app/core/services/message_key_cache.dart';
import 'package:flutter_message_app/core/services/performance_benchmark.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_message_app/core/crypto/message_cipher_v2.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';

/// Gère l'état des conversations et des messages.
class ConversationProvider extends ChangeNotifier {
  final ApiService _apiService;
  final WebSocketService _webSocketService;
  late final KeyDirectoryService _keyDirectory;
  final AuthProvider _authProvider;

  /// 🚀 OPTIMISATION: Limite maximale de messages en mémoire par conversation
  /// Au-delà de cette limite, les messages les plus anciens sont automatiquement retirés
  /// Les messages sont déjà sauvegardés dans LocalMessageStorage, donc pas de perte de données
  static const int _maxMessagesInMemory = 200;

  List<Conversation> _conversations = <Conversation>[];
  /// Cache local des messages, par conversationId
  final Map<String, List<Message>> _messages = {};
  /// Cache mémoire des messages déchiffrés (session courante uniquement)
  /// ⚠️ IMPORTANT: Ce cache n'est PAS persisté pour des raisons de sécurité
  final Map<String, String> _decryptedCache = {};
  /// Presence: userId -> online
  final Map<String, bool> _userOnline = <String, bool>{};
  /// Presence spécifique aux conversations: conversationId -> userId -> online
  final Map<String, Map<String, bool>> _conversationPresence = <String, Map<String, bool>>{};
  /// Read receipts per conversation
  final Map<String, List<Map<String, dynamic>>> _readersByConv = <String, List<Map<String, dynamic>>>{};
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
      debugPrint('👥 [Presence] Initialized current user $currentUserId as online');
    }
    
    // CORRECTION: Utiliser le service global de présence au lieu de configurer nos propres callbacks
    _setupGlobalPresenceListener();
    
    // Configurer les autres callbacks WebSocket de manière asynchrone
    _setupWebSocketCallbacksAsync();
  }
  
  /// Configure l'écoute du service global de présence
  void _setupGlobalPresenceListener() {
    debugPrint('👥 [ConversationProvider] Setting up global presence listener');
    
    // Écouter les changements de présence globale
    GlobalPresenceService().addListener(() {
      debugPrint('👥 [ConversationProvider] Global presence changed, updating local state');
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
    
    debugPrint('👥 [ConversationProvider] Synced with global presence: $_userOnline');
    debugPrint('👥 [ConversationProvider] Synced conversation presence: $_conversationPresence');
  }

  /// Configure les callbacks WebSocket de manière asynchrone
  void _setupWebSocketCallbacksAsync() {
    // Les callbacks de présence sont maintenant gérés par le service global
    debugPrint('👥 [ConversationProvider] Presence callbacks handled by global service');
    
    // Attendre un peu pour les autres callbacks moins critiques
    Future.delayed(const Duration(milliseconds: 100), () {
      debugPrint('👥 [ConversationProvider] Setting up WebSocket callbacks asynchronously');
      _setupWebSocketCallbacks();
    });
  }
  
  
  /// Configure les callbacks WebSocket une seule fois
  void _setupWebSocketCallbacks() {
    // Ne définir les callbacks que s'ils ne sont pas déjà définis
    if (_webSocketService.onNewMessageV2 == null) {
      _webSocketService.onNewMessageV2 = _onWebSocketNewMessageV2;
    }
    // Les callbacks de présence sont maintenant gérés par le service global
    debugPrint('👥 [ConversationProvider] Presence callbacks handled by global service');
    if (_webSocketService.onConvRead == null) {
      _webSocketService.onConvRead = _onConvRead;
    }
    if (_webSocketService.onUserAdded == null) {
      _webSocketService.onUserAdded = _onWebSocketUserAdded;
    }
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

  /// Initialise le cache de déchiffrement (préserve les messages déjà déchiffrés)
  Future<void> _initializeCache() async {
    // CORRECTION: Nettoyer les données obsolètes au démarrage
    await _cleanupObsoleteData();
    
    // Ne pas vider le cache pour préserver les messages déjà déchiffrés
    debugPrint('🚀 ConversationProvider initialisé - Cache de déchiffrement préservé (${_decryptedCache.length} messages)');
  }
  
  /// Nettoie les données obsolètes (conversations supprimées, messages anciens, etc.)
  Future<void> _cleanupObsoleteData() async {
    try {
      // Nettoyer les messages des conversations qui n'existent plus
      final validConvIds = _conversations.map((c) => c.conversationId).toSet();
      final obsoleteConvIds = _messages.keys.where((id) => !validConvIds.contains(id)).toList();
      
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
        debugPrint('🧹 Cleanup completed: ${obsoleteConvIds.length} conversations, ${obsoleteMessageIds.length} messages');
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
    final removedIds = _decryptedCache.keys.where((id) => !keptIds.contains(id)).toList();
    for (final id in removedIds) {
      _decryptedCache.remove(id);
    }
    
    debugPrint('🧹 Trimmed messages for $conversationId: kept ${toKeep.length} most recent, removed $removedCount old messages');
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

  /// Déchiffre un message à la demande et le met en cache
  /// CORRECTION: Vérifie aussi la signature si le message est déjà déchiffré mais signatureValid != true
  Future<String?> decryptMessageIfNeeded(Message message) async {
    final msgId = message.id;
    
    // CORRECTION: Si le message est déjà déchiffré ET signature vérifiée, retourner immédiatement
    if (message.decryptedText != null && message.signatureValid == true) {
      if (!_decryptedCache.containsKey(msgId)) {
        _decryptedCache[msgId] = message.decryptedText!;
      }
      return message.decryptedText;
    }
    
    // Vérifier si déjà dans le cache mémoire
    if (_decryptedCache.containsKey(msgId)) {
      // Si le texte est en cache mais signature pas vérifiée, continuer pour vérifier
      if (message.signatureValid == true) {
        return _decryptedCache[msgId];
      }
      // Sinon, continuer pour vérifier la signature
    }
    
    // Si le message est déjà déchiffré mais signature pas vérifiée, continuer pour vérifier
    if (message.decryptedText != null && message.signatureValid != true) {
      // Continuer pour vérifier la signature
    }
    
    try {
      // Vérifier que le message a des données V2 pour le déchiffrement
      if (message.v2Data == null) {
        const errorText = '[Pas de données V2]';
        _decryptedCache[msgId] = errorText;
        message.decryptedText = errorText;
        return errorText;
      }
      
      // Obtenir nos informations utilisateur et device
      final currentUserId = _authProvider.userId;
      if (currentUserId == null) {
        throw Exception('Utilisateur non authentifié');
      }
      
      final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      final groupId = message.v2Data!['groupId'] as String;
      
      // 🚀 OPTIMISATION SIGNAL: Pré-dériver la message key si pas en cache
      // Cela accélère le déchiffrement pour les messages récents
      await MessageKeyCache.instance.deriveAndCacheMessageKey(
        messageId: msgId,
        groupId: groupId,
        myUserId: currentUserId,
        myDeviceId: myDeviceId,
        messageV2: message.v2Data!,
        keyDirectory: _keyDirectory,
      );
      
      // Déchiffrer le message V2
      final result = await MessageCipherV2.decrypt(
        groupId: groupId,
        myUserId: currentUserId,
        myDeviceId: myDeviceId,
        messageV2: message.v2Data!,
        keyDirectory: _keyDirectory,
      );
      
      // Convertir les bytes en String UTF-8
      final decryptedText = utf8.decode(result['decryptedText'] as Uint8List);
      final signatureValid = result['signatureValid'] as bool;
      
      // Mettre à jour le statut de signature du message
      message.signatureValid = signatureValid;
      
      // CORRECTION: Sauvegarder signatureValid dans la base de données locale
      // (non-bloquant, en arrière-plan)
      LocalMessageStorage.instance.saveMessage(message).catchError((e) {
        debugPrint('⚠️ Erreur sauvegarde signatureValid: $e');
      });
      
      // Enregistrer en cache mémoire uniquement (session courante)
      _decryptedCache[msgId] = decryptedText;
      message.decryptedText = decryptedText;
      
      // CORRECTION: Notifier les listeners pour mettre à jour l'UI
      // 🚀 OPTIMISATION: Utiliser batching pour éviter les freezes
      // Cela garantit que l'UI se met à jour quand signatureValid change
      _notifyListenersBatched();
      
      return decryptedText;
      
    } catch (e) {
      debugPrint('❌ Erreur déchiffrement message $msgId: $e');
      
      // Détecter spécifiquement les erreurs MAC
      if (e.toString().contains('SecretBoxAuthenticationError') || e.toString().contains('MAC')) {
        // Si c'est un message ancien, utiliser un message différent
        final messageTimestamp = message.timestamp;
        final now = DateTime.now().millisecondsSinceEpoch;
        final ageHours = (now - messageTimestamp) / (1000 * 60 * 60);
        
        final errorText = ageHours > 1 
            ? '[📅 Message ancien - Non déchiffrable]' 
            : '[❌ Erreur MAC - Déchiffrement impossible]';
        
        _decryptedCache[msgId] = errorText;
        message.decryptedText = errorText;
        return errorText;
      }
      
      // CORRECTION: Gérer les erreurs de format (messages corrompus)
      if (e.toString().contains('FormatException') || e.toString().contains('Unexpected extension byte')) {
        final errorText = '[📄 Message corrompu - Données invalides]';
        _decryptedCache[msgId] = errorText;
        message.decryptedText = errorText;
        return errorText;
      }
      
      // Gérer les champs manquants dans les données V2
      if (e.toString().contains('eph_pub is empty') || 
          e.toString().contains('is null in messageV2') ||
          e.toString().contains('Structure sender invalide')) {
        final errorText = '[🔧 Message incomplet - Données manquantes]';
        _decryptedCache[msgId] = errorText;
        message.decryptedText = errorText;
        return errorText;
      }
      
      // CORRECTION: Gérer l'erreur "No wrap for this device" (nouvel appareil)
      if (e.toString().contains('No wrap for this device')) {
        debugPrint('🔑 Appareil manquant dans le message - Tentative de synchronisation des clés');
        
        const fallbackErrorText = '[📱 Message envoyé avant votre connexion]';
        
        // Essayer de synchroniser les clés de l'appareil
        try {
          final groupId = message.v2Data!['groupId'] as String;
          final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
          
          // Vérifier si notre appareil est dans le groupe
          final groupDevices = await _keyDirectory.getGroupDevices(groupId);
          final myDeviceInGroup = groupDevices.any((d) => d.deviceId == myDeviceId);
          
          if (!myDeviceInGroup) {
            debugPrint('🔑 Appareil non trouvé dans le groupe - Publication automatique des clés');
            await _ensureMyDeviceKeysArePublished(groupId, myDeviceId);
            
            // Réessayer le déchiffrement après synchronisation
            try {
              final currentUserId = _authProvider.userId;
              if (currentUserId == null) return fallbackErrorText;
              
              final result = await MessageCipherV2.decrypt(
                groupId: groupId,
                myUserId: currentUserId,
                myDeviceId: myDeviceId,
                messageV2: message.v2Data!,
                keyDirectory: _keyDirectory,
              );
              
              final decryptedText = utf8.decode(result['decryptedText'] as Uint8List);
              final signatureValid = result['signatureValid'] as bool;
              
              message.signatureValid = signatureValid;
              _decryptedCache[msgId] = decryptedText;
              message.decryptedText = decryptedText;
              return decryptedText;
            } catch (retryError) {
              debugPrint('❌ Échec du déchiffrement après synchronisation: $retryError');
            }
          }
        } catch (syncError) {
          debugPrint('❌ Erreur synchronisation clés: $syncError');
        }
        
        _decryptedCache[msgId] = fallbackErrorText;
        message.decryptedText = fallbackErrorText;
        return fallbackErrorText;
      }
      
      final errorText = '[Erreur déchiffrement: ${e.toString().substring(0, e.toString().length > 50 ? 50 : e.toString().length)}]';
      _decryptedCache[msgId] = errorText;
      message.decryptedText = errorText;
      return errorText;
    }
  }

  /// Déchiffrement des messages visibles AVEC vérification de signature
  Future<void> decryptVisibleMessagesFast(String conversationId, {
    required int visibleCount,
  }) async {
    final messages = _messages[conversationId] ?? [];
    if (messages.isEmpty) return;
    
    // Déchiffrer seulement les 3 derniers messages (les plus importants)
    final toDecrypt = messages.length > 3 
        ? messages.sublist(messages.length - 3)
        : messages;
    
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
  Future<void> decryptMessagesAroundScrollPosition(String conversationId, {
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
    const batchSize = 1; // Déchiffrer seulement 1 message à la fois pour les anciens
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
          await Future.delayed(const Duration(milliseconds: delayBetweenBatches));
        }
      }
    }
  }

  /// CORRECTION: Déchiffrement uniquement sur demande (ultra-fluide)
  Future<void> decryptMessageOnDemand(String conversationId, String messageId) async {
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
        futures.add(decryptMessageIfNeeded(msg).then((_) {
          processed++;
          // 🚀 OPTIMISATION: Notifier tous les 10 messages déchiffrés (au lieu de 5) pour réduire les freezes
          if (processed % 10 == 0) {
            _notifyListenersBatched();
          }
        }));
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
    debugPrint('👥 [Presence] Checking if $userId is online: $isOnline (map: $_userOnline)');
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
  int getUnreadCount(String conversationId) => _unreadCounts[conversationId] ?? 0;
  
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
      final username = _userUsernames[userId] ?? (userId.length > 8 ? '${userId.substring(0, 8)}...' : userId);
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
  Future<void> fetchConversations() async {
    try {
      _conversations = await _apiService.fetchConversations();
      // 🚀 OPTIMISATION: Notification immédiate pour l'affichage initial (critique)
      _notifyListenersImmediate();
    } catch (e) {
      debugPrint('❌ fetchConversations error: $e');
      rethrow;
    }
  }

  /// Appelle POST /conversations
  Future<String> createConversation(
    String groupId,
    List<String> memberIds,
    String type,
  ) =>
      _apiService.createConversation(
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
      final rawResponse = await _apiService.fetchConversationDetailRaw(conversationId);
      
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
      
      final idx = _conversations
          .indexWhere((c) => c.conversationId == conversationId);
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
            context, 'Impossible de charger la conversation : $e');
      }
      rethrow;
    }
  }

  /// Appelle GET /conversations/:id/messages avec pagination (chargement initial)
  /// Retourne true s'il y a encore des messages à charger, false sinon
  Future<bool> _fetchMessagesWithHasMore(
      BuildContext context,
      String conversationId, {
        int limit = 20,  // Charger seulement les 20 derniers messages
        String? cursor,
      }) async {
    try {
      final items = await _apiService.fetchMessagesV2(
        conversationId: conversationId,
        limit: limit,
        cursor: cursor,
      );
      final List<Message> display = items.map((it) {
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
        
        final msg = Message(
          id: it.messageId,
          conversationId: it.convId,
          senderId: senderUserId,
          encrypted: null,
          iv: null,
          encryptedKeys: const {},
          signatureValid: existingMessage?.signatureValid ?? false, // Préserver le statut existant
          senderPublicKey: null,
          timestamp: it.sentAt,
          v2Data: it.toJson(), // Stocker toutes les données V2 pour le déchiffrement
          decryptedText: existingMessage?.decryptedText, // Préserver le texte déchiffré existant
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
          if (msg.decryptedText != null) {
            decryptedTexts[msg.id] = msg.decryptedText!;
          }
        }
        
        // Restaurer les textes déchiffrés dans les nouveaux messages
        for (final msg in display) {
          if (decryptedTexts.containsKey(msg.id)) {
            msg.decryptedText = decryptedTexts[msg.id];
            _decryptedCache[msg.id] = decryptedTexts[msg.id]!;
          } else if (_decryptedCache.containsKey(msg.id)) {
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
        _messages[conversationId]!.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        
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
        int limit = 20,  // Charger seulement les 20 derniers messages
        String? cursor,
      }) async {
    // 📊 BENCHMARK: Mesurer le chargement initial complet
    return await PerformanceBenchmark.instance.measureAsync(
      cursor == null ? 'fetchMessages_initial' : 'fetchMessages_pagination',
      () async => _fetchMessagesImpl(context, conversationId, limit: limit, cursor: cursor),
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
          debugPrint('⚠️ Erreur initialisation stockage local (non-bloquant): $initError');
          // Continuer avec le serveur même si l'init échoue
        }
        
        // Vérifier si le stockage local est disponible
        if (!LocalMessageStorage.instance.isAvailable) {
          debugPrint('📭 Stockage local non disponible, chargement depuis le serveur');
        } else {
          // 🚀 OPTIMISATION: Limiter strictement à 20 messages max pour éviter la surcharge
          // Même si limit est plus grand, on ne charge jamais plus que nécessaire
          final effectiveLimit = limit > 20 ? 20 : limit; // Limite de sécurité max 20
          debugPrint('💾 Chargement des $effectiveLimit derniers messages depuis le stockage local...');
          
          // 📊 BENCHMARK: Mesurer le chargement depuis la DB locale
          final localMessages = await PerformanceBenchmark.instance.measureAsync(
            'fetchMessages_load_local_db',
            () => LocalMessageStorage.instance.loadMessagesForConversation(
              conversationId,
              limit: effectiveLimit,
            ),
          );
          
          if (localMessages.isNotEmpty) {
            debugPrint('⚡ ${localMessages.length} messages chargés depuis le stockage local (instantané)');
            
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
                mergedMessages.add(Message(
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
                  decryptedText: existing.decryptedText ?? localMsg.decryptedText,
                ));
                mergedIds.add(existing.id);
              } else {
                // Nouveau message depuis la DB
                if (_decryptedCache.containsKey(localMsg.id)) {
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
            
            debugPrint('✅ Messages locaux affichés immédiatement, synchronisation serveur en arrière-plan...');
            
            // Synchroniser avec le serveur en arrière-plan (non-bloquant)
            _syncMessagesFromServer(context, conversationId, limit: limit).catchError((e) {
              debugPrint('⚠️ Erreur synchronisation serveur: $e');
            });
            
            return; // Afficher immédiatement les messages locaux
          } else {
            debugPrint('📭 Aucun message local trouvé pour $conversationId, chargement depuis le serveur');
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
      () => _fetchMessagesWithHasMore(context, conversationId, limit: limit, cursor: cursor),
    );
  }
  
  /// Synchronise les messages depuis le serveur en arrière-plan
  Future<void> _syncMessagesFromServer(
    BuildContext context,
    String conversationId, {
    int limit = 20,
  }) async {
    try {
      // Note: syncState non utilisé pour l'instant, mais peut être utile pour optimisations futures
      await LocalMessageStorage.instance.getSyncState(conversationId);
      
      // CORRECTION: Utiliser le timestamp du dernier message en mémoire (même s'il vient d'un autre device)
      // plutôt que le dernier message local, pour s'assurer de récupérer tous les messages
      // envoyés par d'autres devices du même compte
      int? cursorTimestamp;
      final messagesInMemory = _messages[conversationId];
      if (messagesInMemory != null && messagesInMemory.isNotEmpty) {
        // Utiliser le timestamp du message le plus récent en mémoire
        final lastMessage = messagesInMemory.reduce((a, b) => a.timestamp > b.timestamp ? a : b);
        cursorTimestamp = lastMessage.timestamp;
      } else {
        // Fallback: utiliser le dernier timestamp local
        final lastLocalTimestamp = await LocalMessageStorage.instance.getLastMessageTimestamp(conversationId);
        cursorTimestamp = lastLocalTimestamp;
      }
      
      // Charger les nouveaux messages depuis le serveur
      final items = await _apiService.fetchMessagesV2(
        conversationId: conversationId,
        limit: limit,
        cursor: cursorTimestamp != null ? (cursorTimestamp * 1000).toString() : null,
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
        
        final msg = Message(
          id: item.messageId,
          conversationId: item.convId,
          senderId: senderUserId,
          encrypted: null,
          iv: null,
          encryptedKeys: const {},
          signatureValid: existing?.signatureValid ?? false, // Préserver signatureValid si existe
          senderPublicKey: null,
          timestamp: item.sentAt,
          v2Data: item.toJson(),
          decryptedText: existing?.decryptedText, // Préserver decryptedText si existe
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
        final oldestNew = newMessages.map((m) => m.timestamp).reduce((a, b) => a < b ? a : b);
        final newestExisting = existingMessages.map((m) => m.timestamp).reduce((a, b) => a > b ? a : b);
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
        debugPrint('✅ Synchronisation serveur: ${items.length} nouveaux messages fusionnés');
      }
      
      // Mettre à jour l'état de sync
      // CORRECTION: Utiliser le timestamp du message le plus récent (en mémoire ou nouveau)
      int? latestTimestamp;
      if (items.isNotEmpty) {
        latestTimestamp = items.first.sentAt;
      } else if (messagesInMemory != null && messagesInMemory.isNotEmpty) {
        final lastMessage = messagesInMemory.reduce((a, b) => a.timestamp > b.timestamp ? a : b);
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
      () async => _fetchOlderMessagesImpl(context, conversationId, limit: limit),
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
    final oldestMessage = messages.reduce((a, b) => a.timestamp < b.timestamp ? a : b);
    
    // CORRECTION: Le backend attend un timestamp en millisecondes pour new Date()
    // Vérifier que le timestamp est valide (pas dans le futur)
    final timestamp = oldestMessage.timestamp;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    
    debugPrint('🔍 Debug timestamp - Message: ${oldestMessage.id}, Timestamp: $timestamp, Maintenant: $now');
    
    if (timestamp > now) {
      debugPrint('⚠️ Timestamp invalide détecté: $timestamp (maintenant: $now)');
      debugPrint('⚠️ Message problématique: ${oldestMessage.id}, Date: ${DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)}');
      return false;
    }
    
    // Convertir en millisecondes pour le backend
    final cursorMs = timestamp * 1000;
    debugPrint('🔄 Chargement messages anciens avec cursor: $cursorMs (timestamp ms)');
    
    try {
      final hasMore = await _fetchMessagesWithHasMore(
        context, 
        conversationId, 
        limit: limit, 
        cursor: cursorMs.toString()
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
      final list = await _apiService.getConversationReaders(conversationId: conversationId);
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
        afterTs+1,
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
      final myUserId = _authProvider.userId!;
      final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      final groupId = _conversations.firstWhere((c) => c.conversationId == conversationId).groupId;
      
      // S'assurer que nos clés device sont générées
      await KeyManagerFinal.instance.ensureKeysFor(groupId, myDeviceId);
      
      // Vérifier et publier nos clés si nécessaire
      await _ensureMyDeviceKeysArePublished(groupId, myDeviceId);
      
      // CORRECTION: Récupérer seulement les devices des membres de la conversation
      // pour éviter l'erreur 403 (forbidden) si on inclut des devices de non-membres
      final conversationDetail = await _apiService.fetchConversationDetailRaw(conversationId);
      final members = conversationDetail['members'] as List<dynamic>? ?? [];
      final memberUserIds = members.map((m) => m['userId'] as String).toList();
      
      // CORRECTION: Forcer un refresh du cache AVANT l'envoi pour s'assurer d'avoir tous les devices à jour
      // Cela garantit que tous les devices de l'expéditeur (y compris les autres appareils) sont inclus
      final allGroupDevices = await _keyDirectory.fetchGroupDevices(groupId);
      
      // Filtrer les devices pour ne garder que ceux des membres de la conversation
      var conversationDevices = allGroupDevices
          .where((device) => memberUserIds.contains(device.userId) && device.status == 'active')
          .toList();
      
      // CORRECTION CRITIQUE: Vérifier que notre propre device est bien dans la liste
      // Si ce n'est pas le cas, c'est que le cache n'est pas à jour, on force un refresh
      final myDeviceInList = conversationDevices.any((d) => d.userId == myUserId && d.deviceId == myDeviceId);
      if (!myDeviceInList) {
        // Attendre un peu pour que les clés soient propagées
        await Future.delayed(const Duration(milliseconds: 100));
        // Re-fetch depuis le serveur
        final refreshedDevices = await _keyDirectory.fetchGroupDevices(groupId);
        conversationDevices = refreshedDevices
            .where((device) => memberUserIds.contains(device.userId) && device.status == 'active')
            .toList();
      }
      
      if (conversationDevices.isEmpty) {
        throw Exception('Aucun device actif trouvé pour les membres de la conversation');
      }
      
      final payload = await MessageCipherV2.encrypt(
        groupId: groupId,
        convId: conversationId,
        senderUserId: myUserId,
        senderDeviceId: myDeviceId,
        recipientsDevices: conversationDevices,
        plaintext: Uint8List.fromList(plaintext.codeUnits),
      );
      await _apiService.sendMessageV2(payloadV2: payload);
    } on RateLimitException {
      SnackbarService.showRateLimitError(context);
      rethrow;
    } catch (e) {
      // Si c'est une erreur de clés manquantes, essayer UNE SEULE FOIS
      if ((e.toString().contains('length=0') || e.toString().contains('Failed assertion')) && !plaintext.contains('🔧 RETRY:')) {
        try {
          // Tentative UNIQUE de publication automatique des clés
          final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
          final groupId = _conversations.firstWhere((c) => c.conversationId == conversationId).groupId;
          await _ensureMyDeviceKeysArePublished(groupId, myDeviceId);
          
          // Retry une seule fois avec un marqueur pour éviter la boucle
          SnackbarService.showSuccess(context, 'Clés publiées, nouvelle tentative');
          await sendMessage(context, conversationId, '🔧 RETRY: $plaintext');
          return;
        } catch (retryError) {
          // Si le retry échoue aussi, afficher l'erreur originale
        }
      }
      
      SnackbarService.showError(context, 'Impossible d\'envoyer le message : $e');
      rethrow;
    }
  }


  /// CORRECTION: Synchronisation proactive des clés pour tous les groupes
  Future<void> ensureDeviceKeysForAllGroups() async {
    try {
      final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      final conversations = _conversations;
      
      debugPrint('🔑 Synchronisation proactive des clés pour ${conversations.length} conversations');
      
      for (final conv in conversations) {
        try {
          await _ensureMyDeviceKeysArePublished(conv.groupId, myDeviceId);
        } catch (e) {
          debugPrint('❌ Erreur synchronisation clés pour groupe ${conv.groupId}: $e');
        }
      }
      
      debugPrint('✅ Synchronisation proactive terminée');
    } catch (e) {
      debugPrint('❌ Erreur synchronisation proactive: $e');
    }
  }

  /// S'assurer que les clés de notre device sont publiées pour le groupe
  Future<void> _ensureMyDeviceKeysArePublished(String groupId, String deviceId) async {
    try {
      // Vérifier si les clés ont été régénérées et doivent être republiées
      if (KeyManagerFinal.instance.keysNeedRepublishing) {
        debugPrint('🔑 REPUBLICATION: Les clés ont été régénérées, republication nécessaire');
        
        final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(groupId, deviceId);
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
        await _keyDirectory.fetchGroupDevices(groupId); // Force refresh du cache
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
              debugPrint('⚠️ Device $deviceId est révoqué, publication refusée');
              return; // Ne pas republier un device révoqué
            }
          }
        } catch (e) {
          debugPrint('⚠️ Erreur vérification statut device: $e');
          // Continuer si l'endpoint n'est pas disponible (fallback)
        }
      }
      
      final recipients = await _keyDirectory.getGroupDevices(groupId);
      final myKeysInGroup = recipients.where((r) => r.deviceId == deviceId).toList();
      
      if (myKeysInGroup.isEmpty) {
        debugPrint('🔑 Publication automatique des clés manquantes pour le groupe $groupId');
        
        // S'assurer que les clés device sont générées
        await KeyManagerFinal.instance.ensureKeysFor(groupId, deviceId);
        
        final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(groupId, deviceId);
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
          await _keyDirectory.fetchGroupDevices(groupId); // Force refresh du cache
          debugPrint('✅ Clés publiées et cache mis à jour');
        } catch (e) {
          // Si l'erreur est "device_revoked", c'est normal et on ne doit pas la propager
          if (e.toString().contains('device_revoked') || e.toString().contains('403')) {
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
  void subscribe(String conversationId) =>
      _webSocketService.subscribeConversation(conversationId);

  void unsubscribe(String conversationId) =>
      _webSocketService.unsubscribeConversation(conversationId, userId: _authProvider.userId);

  /// Ajoute un message *localement* (WS ou REST) et notifie.
  void addLocalMessage(Message message) {
    final convId = message.conversationId;
    _messages.putIfAbsent(convId, () => []);
    
    // CORRECTION: Vérifier si le message existe déjà pour éviter les doublons
    final existingIndex = _messages[convId]!.indexWhere((m) => m.id == message.id);
    if (existingIndex >= 0) {
      // Message existe déjà : mettre à jour avec la nouvelle version (préserver signatureValid si déjà vérifié)
      final existing = _messages[convId]![existingIndex];
      // Si la version existante a signatureValid = true, la préserver
      if (existing.signatureValid == true && message.signatureValid != true) {
        message.signatureValid = true;
      }
      // Si la version existante a decryptedText, le préserver
      if (existing.decryptedText != null && message.decryptedText == null) {
        message.decryptedText = existing.decryptedText;
      }
      _messages[convId]![existingIndex] = message;
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

  void _onWebSocketNewMessageV2(Map<String, dynamic> payload) async {
    try {
      final myUserId = _authProvider.userId;
      if (myUserId == null) return;
      final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      final groupId = payload['groupId'] as String;
      final messageId = payload['messageId'] as String;
      final convId = payload['convId'] as String;
      final senderId = (payload['sender'] as Map)['userId'] as String;
      
      // 🚀 OPTIMISATION SIGNAL: Pré-dériver la message key immédiatement
      await MessageKeyCache.instance.deriveAndCacheMessageKey(
        messageId: messageId,
        groupId: groupId,
        myUserId: myUserId,
        myDeviceId: myDeviceId,
        messageV2: payload,
        keyDirectory: _keyDirectory,
      );
      
      // Déchiffrement immédiat (utilisera la clé en cache si disponible)
      final result = await MessageCipherV2.decrypt(
        groupId: groupId,
        myUserId: myUserId,
        myDeviceId: myDeviceId,
        messageV2: payload,
        keyDirectory: _keyDirectory,
      );
      
      final decryptedText = utf8.decode(result['decryptedText'] as Uint8List);
      final signatureValid = result['signatureValid'] as bool;
      
      // Incrémenter le compteur de messages non lus si ce n'est pas notre message
      if (senderId != myUserId) {
        _unreadCounts[convId] = (_unreadCounts[convId] ?? 0) + 1;
        // 🚀 OPTIMISATION: Batching pour les compteurs (non-critique)
        _notifyListenersBatched();
        
        // Afficher une notification si l'utilisateur n'est pas dans cette conversation
        await _showNotificationIfNeeded(convId, senderId, decryptedText);
      }
      
      // Création du message avec texte déchiffré
      final msg = Message(
        id: messageId,
        conversationId: convId,
        senderId: senderId,
        encrypted: null,
        iv: null,
        encryptedKeys: const {},
        signatureValid: signatureValid, // Utiliser le vrai statut de signature
        senderPublicKey: null,
        timestamp: (payload['sentAt'] as num).toInt(),
        v2Data: payload, // Stocker les données V2 pour cohérence
        decryptedText: decryptedText, // Pré-déchiffré via WebSocket
      );
      
      // 🚀 OPTIMISATION SIGNAL: Sauvegarder le message chiffré localement (non-bloquant)
      LocalMessageStorage.instance.saveMessage(msg).catchError((saveError) {
        debugPrint('⚠️ Erreur sauvegarde message local (non-bloquant): $saveError');
      });
      
      // Mettre en cache mémoire uniquement (session courante)
      _decryptedCache[messageId] = decryptedText;
      
      addLocalMessage(msg);
    } catch (e) {
      debugPrint('❌ Erreur déchiffrement message WebSocket: $e');
      
      // CORRECTION: Même en cas d'erreur, ajouter le message avec un texte d'erreur
      // pour que l'utilisateur voie qu'un message a été reçu
      String errorText = '[❌ Erreur déchiffrement]';
      
      // Gérer spécifiquement l'erreur "No wrap for this device"
      if (e.toString().contains('No wrap for this device')) {
        debugPrint('🔑 Message WebSocket - Appareil manquant, tentative de synchronisation');
        
        try {
          final groupId = payload['groupId'] as String;
          final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
          
          // Vérifier si notre appareil est dans le groupe
          final groupDevices = await _keyDirectory.getGroupDevices(groupId);
          final myDeviceInGroup = groupDevices.any((d) => d.deviceId == myDeviceId);
          
          if (!myDeviceInGroup) {
            debugPrint('🔑 Appareil WebSocket non trouvé - Publication automatique des clés');
            await _ensureMyDeviceKeysArePublished(groupId, myDeviceId);
          }
        } catch (syncError) {
          debugPrint('❌ Erreur synchronisation clés WebSocket: $syncError');
        }
        
        errorText = '[📱 Message envoyé avant votre connexion]';
      } else if (e.toString().contains('MissingPluginException') || e.toString().contains('sqflite')) {
        // Erreur liée à sqflite - ne pas bloquer, essayer de déchiffrer quand même
        debugPrint('⚠️ Erreur sqflite détectée, tentative de déchiffrement sans sauvegarde locale');
        try {
          // Réessayer le déchiffrement sans sauvegarder localement
          final result = await MessageCipherV2.decrypt(
            groupId: payload['groupId'] as String,
            myUserId: _authProvider.userId!,
            myDeviceId: await SessionDeviceService.instance.getOrCreateDeviceId(),
            messageV2: payload,
            keyDirectory: _keyDirectory,
          );
          final decryptedText = utf8.decode(result['decryptedText'] as Uint8List);
          errorText = decryptedText; // Succès du déchiffrement
        } catch (decryptError) {
          debugPrint('❌ Échec déchiffrement après erreur sqflite: $decryptError');
          errorText = '[❌ Erreur déchiffrement]';
        }
      }
      
      // Créer un message avec erreur ou texte déchiffré pour affichage
      final msg = Message(
        id: payload['messageId'] as String,
        conversationId: payload['convId'] as String,
        senderId: (payload['sender'] as Map)['userId'] as String,
        encrypted: null,
        iv: null,
        encryptedKeys: const {},
        signatureValid: false,
        senderPublicKey: null,
        timestamp: (payload['sentAt'] as num).toInt(),
        v2Data: payload,
        decryptedText: errorText,
      );
      
      // Mettre en cache même en cas d'erreur
      _decryptedCache[msg.id] = errorText;
      
      // Sauvegarder localement si possible (non-bloquant)
      LocalMessageStorage.instance.saveMessage(msg).catchError((saveError) {
        debugPrint('⚠️ Erreur sauvegarde message local (non-bloquant): $saveError');
      });
      
      addLocalMessage(msg);
    }
  }

  void _onWebSocketUserAdded(String conversationId, String userId) {
    fetchConversations();
  }

  void _onWebSocketConversationJoined() {
    fetchConversations();
  }

  void _onWebSocketGroupCreated(String groupId, String creatorId) {
    debugPrint('🏗️ [WebSocket] Nouveau groupe créé: $groupId par $creatorId');
    // CORRECTION: Rafraîchir la liste des groupes via le GroupProvider
    // Note: Le GroupProvider sera notifié via son propre callback WebSocket
  }

  void _onWebSocketConversationCreated(String convId, String groupId, String creatorId) {
    debugPrint('💬 [WebSocket] Nouvelle conversation créée: $convId dans $groupId par $creatorId');
    // CORRECTION: Rafraîchir immédiatement la liste des conversations
    fetchConversations();
    // 🚀 OPTIMISATION: Batching pour les événements WebSocket (non-critique)
    _notifyListenersBatched();
  }

  // Presence + read receipts hooks (UI can observe derived state later)
  // Les méthodes _onPresenceUpdate et _onPresenceConversation sont maintenant gérées par GlobalPresenceService
  

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
  
  /// Affiche une notification si nécessaire
  Future<void> _showNotificationIfNeeded(String conversationId, String senderId, String messageText) async {
    try {
      // Vérifier si l'utilisateur est actuellement dans cette conversation
      final isInCurrentConversation = _isUserInCurrentConversation(conversationId);
      
      if (!isInCurrentConversation) {
        // Obtenir le nom de l'expéditeur
        final senderName = await _getSenderName(senderId);
        
        // Tronquer le message pour la notification
        final truncatedMessage = messageText.length > 50 
            ? '${messageText.substring(0, 50)}...'
            : messageText;
        
        await NotificationService.showMessageNotification(
          title: senderName.isNotEmpty ? senderName : 'Nouveau message',
          body: truncatedMessage,
          conversationId: conversationId,
          senderName: senderName,
        );
      }
    } catch (e) {
      debugPrint('❌ Erreur affichage notification: $e');
    }
  }
  
  /// Vérifie si l'utilisateur est actuellement dans la conversation spécifiée
  bool _isUserInCurrentConversation(String conversationId) {
    // Cette méthode devrait être implémentée pour vérifier l'état de l'UI
    // Pour l'instant, on retourne false pour toujours afficher les notifications
    return false;
  }
  
  /// Obtient le nom d'un utilisateur par son ID
  Future<String> _getSenderName(String userId) async {
    try {
      // Chercher dans les membres des groupes
      for (final conversation in _conversations) {
        // Cette logique devrait être améliorée pour récupérer le vrai nom
        // Pour l'instant, on retourne l'ID tronqué
        if (conversation.conversationId.isNotEmpty) {
          return userId.length > 8 ? '${userId.substring(0, 8)}...' : userId;
        }
      }
    } catch (e) {
      debugPrint('❌ Erreur récupération nom expéditeur: $e');
    }
    return userId.length > 8 ? '${userId.substring(0, 8)}...' : userId;
  }
}
