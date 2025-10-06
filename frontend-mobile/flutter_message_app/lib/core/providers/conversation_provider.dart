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
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_message_app/core/crypto/message_cipher_v2.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';

/// Gère l’état des conversations et des messages.
class ConversationProvider extends ChangeNotifier {
  final ApiService _apiService;
  final WebSocketService _webSocketService;
  late final KeyDirectoryService _keyDirectory;
  final AuthProvider _authProvider;

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
      notifyListeners();
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
  Future<String?> decryptMessageIfNeeded(Message message) async {
    final msgId = message.id;
    
    // Vérifier si déjà déchiffré
    if (_decryptedCache.containsKey(msgId)) {
      return _decryptedCache[msgId];
    }
    
    // Vérifier si déjà dans le message
    if (message.decryptedText != null) {
      _decryptedCache[msgId] = message.decryptedText!;
      return message.decryptedText;
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
      
      // Déchiffrer le message V2
      final result = await MessageCipherV2.decrypt(
        groupId: message.v2Data!['groupId'] as String,
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
      debugPrint('🔐 [Decrypt] Message $msgId - Signature: ${signatureValid ? "✅" : "❌"}');
      
      // Enregistrer en cache mémoire uniquement (session courante)
      _decryptedCache[msgId] = decryptedText;
      message.decryptedText = decryptedText;
      
      debugPrint('✅ Message $msgId déchiffré avec succès - Signature: ${signatureValid ? "✅" : "❌"}');
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
      
      final errorText = '[Erreur déchiffrement: ${e.toString().substring(0, e.toString().length > 50 ? 50 : e.toString().length)}]';
      _decryptedCache[msgId] = errorText;
      message.decryptedText = errorText;
      return errorText;
    }
  }

  /// Déchiffre seulement les messages visibles (optimisation)
  Future<void> decryptVisibleMessages(String conversationId, {
    required int visibleCount,
  }) async {
    final messages = _messages[conversationId] ?? [];
    if (messages.isEmpty) return;
    
    // Déchiffrer seulement les derniers X messages (les plus récents)
    final toDecrypt = messages.length > visibleCount 
        ? messages.sublist(messages.length - visibleCount)
        : messages;
    
    // Déchiffrer en parallèle pour optimiser (max 3 simultanés)
    final futures = <Future<void>>[];
    int concurrent = 0;
    const maxConcurrent = 3;
    
    for (final msg in toDecrypt) {
      if (msg.decryptedText == null && msg.v2Data != null) {
        if (concurrent >= maxConcurrent) {
          // Attendre qu'un déchiffrement se termine avant d'en lancer un autre
          await Future.wait(futures.take(maxConcurrent));
          futures.clear();
          concurrent = 0;
        }
        
        futures.add(decryptMessageIfNeeded(msg).then((_) => notifyListeners()));
        concurrent++;
      }
    }
    
    // Attendre la fin de tous les déchiffrements
    if (futures.isNotEmpty) {
      await Future.wait(futures);
      notifyListeners();
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
    
    // Déchiffrer en parallèle pour optimiser (max 2 simultanés pour éviter le freeze)
    final futures = <Future<void>>[];
    int concurrent = 0;
    const maxConcurrent = 2;
    
    for (final msg in toDecrypt) {
      if (msg.decryptedText == null && msg.v2Data != null) {
        if (concurrent >= maxConcurrent) {
          // Attendre qu'un déchiffrement se termine avant d'en lancer un autre
          await Future.wait(futures.take(maxConcurrent));
          futures.clear();
          concurrent = 0;
        }
        
        futures.add(decryptMessageIfNeeded(msg).then((_) => notifyListeners()));
        concurrent++;
      }
    }
    
    // Attendre la fin de tous les déchiffrements
    if (futures.isNotEmpty) {
      await Future.wait(futures);
      notifyListeners();
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
          // Notifier tous les 5 messages déchiffrés pour l'UX
          if (processed % 5 == 0) {
            notifyListeners();
          }
        }));
      }
    }
    
    // Attendre la fin et notifier une dernière fois
    if (futures.isNotEmpty) {
      await Future.wait(futures);
      notifyListeners();
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
    notifyListeners();
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
      notifyListeners();
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
  Future<Conversation> fetchConversationDetail(
      BuildContext context,
      String conversationId,
  ) async {
    try {
      final convo = await _apiService.fetchConversationDetail(conversationId);
      
      // Extraire les informations des membres depuis la réponse brute
      final rawResponse = await _apiService.fetchConversationDetailRaw(conversationId);
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
      
      final idx = _conversations
          .indexWhere((c) => c.conversationId == conversationId);
      if (idx >= 0) {
        _conversations[idx] = convo;
      } else {
        _conversations.add(convo);
      }
      notifyListeners();
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
  Future<void> fetchMessages(
      BuildContext context,
      String conversationId, {
        int limit = 25,  // Charger seulement les 25 derniers messages
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
        
        return Message(
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
      } else {
        // Pour la pagination, ajouter au début (messages plus anciens)
        final existing = _messages[conversationId] ?? [];
        _messages[conversationId] = [...display, ...existing];
        // Re-trier après ajout (plus ancien en premier)
        _messages[conversationId]!.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      }
      
      notifyListeners();
    } on RateLimitException {
      SnackbarService.showRateLimitError(context);
    } catch (e) {
      debugPrint('❌ fetchMessages error: $e');
      // pas de popup ici, on peut juste loguer
    }
  }

  /// Charge les messages plus anciens (pagination vers le haut)
  Future<void> fetchOlderMessages(
    BuildContext context,
    String conversationId, {
      int limit = 25,
    }) async {
    final messages = _messages[conversationId] ?? [];
    if (messages.isEmpty) return;
    
    // Utiliser le timestamp du message le plus ancien comme cursor
    final oldestMessage = messages.reduce((a, b) => a.timestamp < b.timestamp ? a : b);
    final cursorTimestamp = oldestMessage.timestamp;
    
    try {
      await fetchMessages(context, conversationId, limit: limit, cursor: cursorTimestamp.toString());
    } catch (e) {
      debugPrint('❌ fetchOlderMessages error: $e');
    }
  }

  Future<void> refreshReaders(String conversationId) async {
    try {
      final list = await _apiService.getConversationReaders(conversationId: conversationId);
      _readersByConv[conversationId] = list;
      notifyListeners();
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
        notifyListeners();
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
      
      final recipients = await _keyDirectory.fetchGroupDevices(groupId);
      
      final payload = await MessageCipherV2.encrypt(
        groupId: groupId,
        convId: conversationId,
        senderUserId: myUserId,
        senderDeviceId: myDeviceId,
        recipientsDevices: recipients,
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
      
      final recipients = await _keyDirectory.getGroupDevices(groupId);
      final myKeysInGroup = recipients.where((r) => r.deviceId == deviceId).toList();
      
      if (myKeysInGroup.isEmpty) {
        debugPrint('🔑 Publication automatique des clés manquantes pour le groupe $groupId');
        
        // S'assurer que les clés device sont générées
        await KeyManagerFinal.instance.ensureKeysFor(groupId, deviceId);
        
        final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(groupId, deviceId);
        final sigPub = pubKeys['pk_sig']!;
        final kemPub = pubKeys['pk_kem']!;
        
        await _apiService.publishGroupDeviceKey(
          groupId: groupId,
          deviceId: deviceId,
          pkSigB64: sigPub,
          pkKemB64: kemPub,
        );
        
        // Invalider le cache pour que les nouvelles clés soient récupérées
        await _keyDirectory.fetchGroupDevices(groupId); // Force refresh du cache
        debugPrint('✅ Clés publiées et cache mis à jour');
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
    _messages[convId]!.add(message);
    notifyListeners();
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
      
      debugPrint('📨 Message WebSocket reçu: $messageId');
      
      // Déchiffrement immédiat
      final result = await MessageCipherV2.decrypt(
        groupId: groupId,
        myUserId: myUserId,
        myDeviceId: myDeviceId,
        messageV2: payload,
        keyDirectory: _keyDirectory,
      );
      
      final decryptedText = utf8.decode(result['decryptedText'] as Uint8List);
      final signatureValid = result['signatureValid'] as bool;
      debugPrint('✅ Message WebSocket déchiffré: ${decryptedText.substring(0, math.min(20, decryptedText.length))}... - Signature: ${signatureValid ? "✅" : "❌"}');
      
      // Incrémenter le compteur de messages non lus si ce n'est pas notre message
      if (senderId != myUserId) {
        _unreadCounts[convId] = (_unreadCounts[convId] ?? 0) + 1;
        notifyListeners();
        
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
      
      // Mettre en cache mémoire uniquement (session courante)
      _decryptedCache[messageId] = decryptedText;
      
      addLocalMessage(msg);
      debugPrint('📨 Message WebSocket ajouté à la conversation');
    } catch (e) {
      debugPrint('❌ Erreur déchiffrement message WebSocket: $e');
      
      // Créer un message avec erreur pour affichage
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
        decryptedText: '[❌ Erreur déchiffrement]',
      );
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
    notifyListeners();
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
    notifyListeners();
  }
  
  void _onTypingStop(String convId, String userId) {
    _typingUsers[convId]?.remove(userId);
    notifyListeners();
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
