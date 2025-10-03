import 'dart:math';

import 'package:flutter/material.dart';
// V1 encryption removed
import 'package:provider/provider.dart';
// V1 RSA/AES-CBC removed

import '../../core/models/conversation.dart';
import '../../core/models/message.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/providers/group_provider.dart';
// SnackbarService not used here directly
import '../../core/services/websocket_service.dart';
import '../helpers/extensions.dart';
import '../widgets/message_bubble.dart';

class ConversationScreen extends StatefulWidget {
  final String conversationId;
  const ConversationScreen({Key? key, required this.conversationId})
      : super(key: key);

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  late final ConversationProvider _conversationProvider;
  // auth provider kept for potential future use
  late final AuthProvider _authProvider;
  late final GroupProvider _groupProvider;

  static const int _visibleCount = 10;
  static const int _chunkSize = 10;

  static const double _nearBottomThreshold = 100.0; 
  static const double _showButtonThreshold = 300.0;

  bool _isLoading = false;
  bool _initialDecryptDone = false;
  bool _isAtBottom = true;
  bool _showScrollToBottom = false;
  // cached details no longer used in v2 flow
  Conversation? _conversationDetail;

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _conversationProvider = context.read<ConversationProvider>();
    _authProvider = context.read<AuthProvider>();
    _groupProvider = context.read<GroupProvider>();

    // Écoute la position
    _scrollController.addListener(_onScroll);

    WebSocketService.instance.connect(context);
    _conversationProvider.subscribe(widget.conversationId);
    _conversationProvider.addListener(_onMessagesUpdated);

    _loadData();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    final atBottom = offset < _nearBottomThreshold;
    final showButton = offset > _showButtonThreshold;

    if (atBottom != _isAtBottom || showButton != _showScrollToBottom) {
      setState(() {
        _isAtBottom = atBottom;
        _showScrollToBottom = showButton;
      });
    }
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      _conversationDetail = await _conversationProvider.fetchConversationDetail(
        context, widget.conversationId,
      );

      final cached = _conversationProvider.messagesFor(widget.conversationId);
      if (cached.isNotEmpty) {
        final lastTs = cached
            .map((m) => m.timestamp)
            .reduce((a, b) => a > b ? a : b);
        await _conversationProvider.fetchMessagesAfter(
          context,
          widget.conversationId,
          DateTime.fromMillisecondsSinceEpoch(lastTs * 1000),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom(animate: false);
        });
        setState(() => _isLoading = false);
        await _decryptVisibleMessages();
        _decryptRemainingMessages().then((_) => setState(() {}));
        _initialDecryptDone = true;
        return;
      }

      await _conversationProvider.fetchMessages(
        context, widget.conversationId,
      );
      // POST read receipt on open
      await _conversationProvider.postRead(widget.conversationId);
      // Fetch initial readers
      await context.read<ConversationProvider>().refreshReaders(widget.conversationId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom(animate: false);
      });
      setState(() => _isLoading = false);
      await _decryptVisibleMessages();
      await _decryptRemainingMessages();
      setState(() {});
      _initialDecryptDone = true;
    } catch (e) {
      debugPrint('Erreur chargement conversation : $e');
    }
  }

  Future<void> _decryptVisibleMessages() async {
    final list = _conversationProvider.messagesFor(widget.conversationId).reversed.toList();
    for (var i = 0; i < min(_visibleCount, list.length); i++) {
      await _decryptSingleMessage(list[i]);
      setState(() {});
    }
  }

  Future<void> _decryptRemainingMessages() async {
    final list = _conversationProvider.messagesFor(widget.conversationId).reversed.toList();
    if (list.length <= _visibleCount) return;
    final rest = list.sublist(_visibleCount);
    for (var start = 0; start < rest.length; start += _chunkSize) {
      final end = min(start + _chunkSize, rest.length);
      final chunk = rest.sublist(start, end);
      await Future.wait(chunk.map(_decryptSingleMessage));
      setState(() {});
    }
  }

  Future<void> _decryptSingleMessage(Message msg) async {
    // Placeholder: legacy Message model; decryption will be handled when wiring v2 in provider
    msg.decryptedText ??= '[Chiffré]';
  }

  void _onMessagesUpdated() {
    if (!_initialDecryptDone) return;
    if (_isAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
    // Décrypte les nouveaux messages dès qu'ils arrivent
    for (final msg in _conversationProvider.messagesFor(widget.conversationId)) {
      if (msg.decryptedText == null) {
        _decryptSingleMessage(msg).then((_) => setState(() {}));
      }
    }
  }

  Future<void> _onSendPressed() async {
    final plainText = _textController.text.trim();
    if (plainText.isEmpty) return;
    _textController.clear();
    await _conversationProvider.sendMessage(context, widget.conversationId, plainText);
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final target = 0.0;
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  @override
  void dispose() {
    WebSocketService.instance.unsubscribeConversation(widget.conversationId);
    _conversationProvider.removeListener(_onMessagesUpdated);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final raw = context
        .watch<ConversationProvider>()
        .messagesFor(widget.conversationId);
    final currentUserId = context.read<AuthProvider>().userId ?? '';
    final maxBubbleWidth = context.maxBubbleWidth;

    // Construire chatItems (chronologique)
    final List<Widget> chatItems = [];
    DateTime? lastDate;
    for (final msg in raw) {
      final msgDate = DateTime.fromMillisecondsSinceEpoch(msg.timestamp * 1000)
          .toLocal();
      final dateOnly = DateTime(msgDate.year, msgDate.month, msgDate.day);

      if (lastDate == null || lastDate != dateOnly) {
        chatItems.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: Text(
                dateOnly.toChatDateHeader(),
                style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        );
        lastDate = dateOnly;
      }

      final index = raw.indexOf(msg);
      final sameAsPrevious = index > 0 &&
          raw[index - 1].senderId == msg.senderId;
      final sameAsNext = index < raw.length - 1 &&
          raw[index + 1].senderId == msg.senderId;

      final isMe = msg.senderId == currentUserId;
      final text = msg.decryptedText ?? '[Chiffré]';
      final time = msgDate.toHm();
      final senderUsername = isMe
          ? ''
          : (_groupProvider.members
                  .firstWhere(
                    (m) => m['userId'] == msg.senderId,
                    orElse: () => <String, dynamic>{},
                  )['username']
              as String? ?? '')
              .trim();

      chatItems.add(
        MessageBubble(
          isMe: isMe,
          text: text,
          time: time,
          signatureValid: msg.signatureValid,
          senderInitial: isMe ? '' : msg.senderId[0].toUpperCase(),
          senderUsername: senderUsername,
          sameAsPrevious: sameAsPrevious,
          sameAsNext: sameAsNext,
          maxWidth: maxBubbleWidth,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Conversation')),
      body: Stack(
        children: [
          Column(
            children: [
              // Presence/readers bar
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Builder(
                  builder: (context) {
                    final readers = context.watch<ConversationProvider>().readersFor(widget.conversationId);
                    if (readers.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final names = readers.map((r) => r['username'] as String? ?? r['userId'] as String).toList();
                    return Text(
                      'Vu par: ${names.join(', ')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  },
                ),
              ),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        controller: _scrollController,
                        reverse: true,
                        physics: const ClampingScrollPhysics(),
                        children: chatItems.reversed.toList(),
                      ),
              ),

              // zone de saisie
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 4),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        decoration: const InputDecoration(
                          hintText: 'Écrire un message…',
                          border: InputBorder.none,
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _onSendPressed(),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: _onSendPressed,
                    ),
                  ],
                ),
              ),
            ],
          ),

          if (_showScrollToBottom)
            Positioned(
              bottom: 80,
              right: 16,
              child: FloatingActionButton(
                mini: true,
                onPressed: () => _scrollToBottom(),
                child: const Icon(Icons.arrow_downward),
              ),
            ),
        ],
      ),
    );
  }
}
