import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/models/conversation.dart';
import 'package:flutter_message_app/core/models/message.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/services/api_service.dart';
import 'package:flutter_message_app/core/services/snackbar_service.dart';
import 'package:flutter_message_app/core/services/websocket_service.dart';
import 'package:flutter_message_app/core/services/key_directory_service.dart';
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_message_app/core/crypto/message_cipher_v2.dart';
import 'package:flutter_message_app/core/crypto/key_manager_v2.dart';

/// Gère l’état des conversations et des messages.
class ConversationProvider extends ChangeNotifier {
  final ApiService _apiService;
  final WebSocketService _webSocketService;
  late final KeyDirectoryService _keyDirectory;
  final AuthProvider _authProvider;

  List<Conversation> _conversations = <Conversation>[];
  /// Cache local des messages, par conversationId
  final Map<String, List<Message>> _messages = {};
  /// Messages déchiffrés (cache des textes en clair)
  final Map<String, String> _decryptedCache = {};
  /// Presence: userId -> online
  final Map<String, bool> _userOnline = <String, bool>{};
  /// Presence: userId -> device count
  final Map<String, int> _userDeviceCount = <String, int>{};
  /// Read receipts per conversation
  final Map<String, List<Map<String, dynamic>>> _readersByConv = <String, List<Map<String, dynamic>>>{};

  ConversationProvider(AuthProvider authProvider)
      : _apiService = ApiService(authProvider),
        _webSocketService = WebSocketService.instance,
        _authProvider = authProvider {
    _keyDirectory = KeyDirectoryService(_apiService);
    _webSocketService.onNewMessageV2 = _onWebSocketNewMessageV2;
    _webSocketService.onPresenceUpdate = _onPresenceUpdate;
    _webSocketService.onConvRead = _onConvRead;
    _webSocketService.onUserAdded = _onWebSocketUserAdded;
    _webSocketService.onConversationJoined = _onWebSocketConversationJoined;
  }

  Future<void> postRead(String conversationId) async {
    try {
      await _apiService.postConversationRead(conversationId: conversationId);
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
        debugPrint('⚠️ Message $msgId sans données V2, impossible à déchiffrer');
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
      final decryptedBytes = await MessageCipherV2.decrypt(
        groupId: message.v2Data!['groupId'] as String,
        myUserId: currentUserId,
        myDeviceId: myDeviceId,
        messageV2: message.v2Data!,
        keyDirectory: _keyDirectory,
      );
      
      // Convertir les bytes en String UTF-8
      final decryptedText = utf8.decode(decryptedBytes);
      
      // Enregistrer en cache et dans l'objet message
      _decryptedCache[msgId] = decryptedText;
      message.decryptedText = decryptedText;
      
      debugPrint('✅ Message $msgId déchiffré avec succès');
      return decryptedText;
      
    } catch (e) {
      debugPrint('❌ Erreur déchiffrement message $msgId: $e');
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
    
    // Déchiffrer en parallèle pour optimiser
    await Future.wait(toDecrypt.map(decryptMessageIfNeeded));
    notifyListeners();
  }

  /// Méthode de debug pour diagnostiquer les problèmes de déchiffrement
  void debugDecryptionStatus(String conversationId) {
    final messages = _messages[conversationId] ?? [];
    debugPrint('🔍 Debug déchiffrement conversation $conversationId:');
    debugPrint('  📥 Total messages: ${messages.length}');
    debugPrint('  🔐 Messages avec données V2: ${messages.where((m) => m.v2Data != null).length}');
    debugPrint('  ✅ Messages déchiffrés: ${messages.where((m) => m.decryptedText != null).length}');
    debugPrint('  💾 Cache taille: ${_decryptedCache.length}');
    
    for (int i = 0; i < math.min(5, messages.length); i++) {
      final msg = messages[messages.length - 1 - i]; // Derniers messages
      debugPrint('  📄 Message ${i + 1}: ${msg.id.substring(0, 8)}...');
      debugPrint('    - V2Data: ${msg.v2Data != null ? "✅" : "❌"}');
      debugPrint('    - Déchiffré: ${msg.decryptedText != null ? "✅" : "❌"}');
      debugPrint('    - Cache: ${_decryptedCache.containsKey(msg.id) ? "✅" : "❌"}');
    }
  }
  bool isUserOnline(String userId) => _userOnline[userId] == true;
  int onlineUsersCount() => _userOnline.values.where((v) => v == true).length;
  List<Map<String, dynamic>> readersFor(String conversationId) =>
      _readersByConv[conversationId] ?? const <Map<String, dynamic>>[];

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
      SnackbarService.showRateLimitError(context);
      rethrow;
    } catch (e) {
      debugPrint('❌ fetchConversationDetail error: $e');
      SnackbarService.showError(
          context, 'Impossible de charger la conversation : $e');
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
      final List<Message> display = items.map((it) => Message(
        id: it.messageId,
        conversationId: it.convId,
        senderId: (it.sender['userId'] as String),
        encrypted: null,
        iv: null,
        encryptedKeys: const {},
        signatureValid: true,
        senderPublicKey: null,
        timestamp: it.sentAt,
        v2Data: it.toJson(), // Stocker toutes les données V2 pour le déchiffrement
        decryptedText: null,
      )).toList();
      
      // Pour le chargement initial, remplacer complètement
      if (cursor == null) {
        _messages[conversationId] = display;
      } else {
        // Pour la pagination, ajouter au début (messages plus anciens)
        final existing = _messages[conversationId] ?? [];
        _messages[conversationId] = [...display, ...existing];
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
      await KeyManagerV2.instance.ensureKeysFor(groupId, myDeviceId);
      
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
      debugPrint('❌ sendMessage error: $e');
      
      // Si c'est une erreur de clés manquantes, essayer UNE SEULE FOIS
      if ((e.toString().contains('length=0') || e.toString().contains('Failed assertion')) && !plaintext.contains('🔧 RETRY:')) {
        try {
          debugPrint('🔧 Tentative UNIQUE de publication automatique des clés...');
          final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
          final groupId = _conversations.firstWhere((c) => c.conversationId == conversationId).groupId;
          await _ensureMyDeviceKeysArePublished(groupId, myDeviceId);
          
          // Retry une seule fois avec un marqueur pour éviter la boucle
          SnackbarService.showSuccess(context, 'Clés publiées, nouvelle tentative');
          await sendMessage(context, conversationId, '🔧 RETRY: $plaintext');
          return;
        } catch (retryError) {
          debugPrint('❌ Retry failed: $retryError');
        }
      }
      
      SnackbarService.showError(context, 'Impossible d\'envoyer le message : $e');
      rethrow;
    }
  }

  /// S'assurer que les clés de notre device sont publiées pour le groupe
  Future<void> _ensureMyDeviceKeysArePublished(String groupId, String deviceId) async {
    try {
      final recipients = await _keyDirectory.getGroupDevices(groupId);
      final myKeysInGroup = recipients.where((r) => r.deviceId == deviceId).toList();
      
      if (myKeysInGroup.isEmpty) {
        debugPrint('🔑 Publication automatique des clés manquantes pour le groupe $groupId');
        
        // S'assurer que les clés device sont générées
        await KeyManagerV2.instance.ensureKeysFor(groupId, deviceId);
        
        final pubKeys = await KeyManagerV2.instance.publicKeysBase64(groupId, deviceId);
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
      _webSocketService.unsubscribeConversation(conversationId);

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
      final clear = await MessageCipherV2.decrypt(
        groupId: groupId,
        myUserId: myUserId,
        myDeviceId: myDeviceId,
        messageV2: payload,
        keyDirectory: _keyDirectory,
      );
      final msg = Message(
        id: payload['messageId'] as String,
        conversationId: payload['convId'] as String,
        senderId: (payload['sender'] as Map)['userId'] as String,
        encrypted: null,
        iv: null,
        encryptedKeys: const {},
        signatureValid: true,
        senderPublicKey: null,
        timestamp: (payload['sentAt'] as num).toInt(),
        v2Data: payload, // Stocker les données V2 pour cohérence avec fetchMessages
        decryptedText: String.fromCharCodes(clear), // Pré-déchiffré via WebSocket
      );
      addLocalMessage(msg);
    } catch (e) {
      debugPrint('❌ decrypt v2 ws message error: $e');
    }
  }

  void _onWebSocketUserAdded(String conversationId, String userId) {
    fetchConversations();
  }

  void _onWebSocketConversationJoined() {
    fetchConversations();
  }

  // Presence + read receipts hooks (UI can observe derived state later)
  void _onPresenceUpdate(String userId, bool online, int count) {
    _userOnline[userId] = online;
    _userDeviceCount[userId] = count;
    notifyListeners();
  }

  void _onConvRead(String convId, String userId, String at) {
    // Refresh readers to fetch usernames and timestamps
    // ignore: discarded_futures
    refreshReaders(convId);
  }
}
