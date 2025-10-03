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
import 'package:flutter_message_app/core/crypto/message_cipher_v2.dart';

/// Gère l’état des conversations et des messages.
class ConversationProvider extends ChangeNotifier {
  final ApiService _apiService;
  final WebSocketService _webSocketService;
  late final KeyDirectoryService _keyDirectory;
  final AuthProvider _authProvider;

  List<Conversation> _conversations = <Conversation>[];
  /// Cache local des messages, par conversationId
  final Map<String, List<Message>> _messages = {};
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

  /// Appelle GET /conversations/:id/messages
  Future<void> fetchMessages(
      BuildContext context,
      String conversationId,
  ) async {
    try {
      final items = await _apiService.fetchMessagesV2(conversationId: conversationId);
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
        decryptedText: null,
      )).toList();
      _messages[conversationId] = display;
      notifyListeners();
    } on RateLimitException {
      SnackbarService.showRateLimitError(context);
    } catch (e) {
      debugPrint('❌ fetchMessages error: $e');
      // pas de popup ici, on peut juste loguer
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
      SnackbarService.showError(context, 'Impossible d’envoyer le message : $e');
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
        decryptedText: String.fromCharCodes(clear),
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
