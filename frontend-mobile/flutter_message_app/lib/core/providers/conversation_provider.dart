import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/models/conversation.dart';
import 'package:flutter_message_app/core/models/message.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/services/api_service.dart';
import 'package:flutter_message_app/core/services/snackbar_service.dart';
import 'package:flutter_message_app/core/services/websocket_service.dart';

/// Gère l’état des conversations et des messages.
class ConversationProvider extends ChangeNotifier {
  final ApiService _apiService;
  final WebSocketService _webSocketService;

  List<Conversation> _conversations = <Conversation>[];
  /// Cache local des messages, par conversationId
  final Map<String, List<Message>> _messages = {};

  ConversationProvider(AuthProvider authProvider)
      : _apiService = ApiService(authProvider),
        _webSocketService = WebSocketService.instance {
    // On branche le handler WS dès la construction
    _webSocketService.onNewMessage = _onWebSocketNewMessage;
    _webSocketService.onUserAdded = _onWebSocketUserAdded;
    _webSocketService.onConversationJoined = _onWebSocketConversationJoined;
  }

  /// Liste des conversations chargées.
  List<Conversation> get conversations => _conversations;

  /// Messages en mémoire pour une conversation donnée.
  List<Message> messagesFor(String conversationId) =>
      _messages[conversationId] ?? <Message>[];

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
    List<String> userIds,
    Map<String, String> encryptedSecrets,
    String creatorSignature,
  ) =>
      _apiService.createConversation(
        groupId: groupId,
        userIds: userIds,
        encryptedSecrets: encryptedSecrets,
        creatorSignature: creatorSignature,
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
    final cached = _messages[conversationId];
    if (cached != null && cached.isNotEmpty) {
      return;
    }
    try {
      _messages[conversationId] =
          await _apiService.fetchMessages(conversationId);
      notifyListeners();
    } on RateLimitException {
      SnackbarService.showRateLimitError(context);
    } catch (e) {
      debugPrint('❌ fetchMessages error: $e');
      // pas de popup ici, on peut juste loguer
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
    String encryptedPayload,
    Map<String, String> encryptedKeys,
  ) async {
    try {
      final sent = await _apiService.sendMessage(
        conversationId: conversationId,
        encryptedMessage: encryptedPayload,
        encryptedKeys: encryptedKeys,
      );
      //addLocalMessage(sent);
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

  void _onWebSocketNewMessage(Message msg) {
    addLocalMessage(msg);
  }

  void _onWebSocketUserAdded(String conversationId, String userId) {
    fetchConversations();
  }

  void _onWebSocketConversationJoined() {
    fetchConversations();
  }
}
