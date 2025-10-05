import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/providers/group_provider.dart';
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
  late final GroupProvider _groupProvider;

  static const int _messagesPerPage = 25;  // Messages chargés par pagination

  static const double _nearBottomThreshold = 100.0; 
  static const double _showButtonThreshold = 300.0;

  bool _isLoading = false;
  bool _initialDecryptDone = false;
  bool _isAtBottom = true;
  bool _showScrollToBottom = false;
  bool _isDecrypting = false;
  int _visibleCount = 20; // Nombre de messages visibles pour l'optimisation

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _conversationProvider = context.read<ConversationProvider>();
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
    final maxExtent = _scrollController.position.maxScrollExtent;
    final atBottom = (maxExtent - offset) < _nearBottomThreshold;
    final showButton = (maxExtent - offset) > _showButtonThreshold;

    // Déclencher le chargement de messages plus anciens quand on approche du haut
    const loadMoreThreshold = 200.0;
    if (offset < loadMoreThreshold && !_isLoading && _initialDecryptDone) {
      _loadOlderMessages();
    }

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
      // 1) Charger les détails de la conversation
      await _conversationProvider.fetchConversationDetail(
        context, widget.conversationId,
      );

      // 2) Charger seulement les X derniers messages (pagination optimisée)
      await _conversationProvider.fetchMessages(
        context, 
        widget.conversationId,
        limit: _messagesPerPage,  // Limiter à 25 messages au lieu de TOUT charger
      );
      
      // 3) POST read receipt on open
      await _conversationProvider.postRead(widget.conversationId);
      
      // 4) Fetch initial readers
      await context.read<ConversationProvider>().refreshReaders(widget.conversationId);
      
      // 5) Scroll vers le bas pour montrer les messages récents
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom(animate: false);
      });
      
      setState(() => _isLoading = false);
      
      // 6) Déchiffrer UNIQUEMENT les messages visibles (optimisation)
      await _conversationProvider.decryptVisibleMessages(
        widget.conversationId, 
        visibleCount: _visibleCount,
      );
      
      _initialDecryptDone = true;
      setState(() {});
      
    } catch (e) {
      debugPrint('❌ Erreur chargement conversation : $e');
      setState(() => _isLoading = false);
    }
  }

  /// Charge les messages plus anciens lors du scroll vers le haut
  Future<void> _loadOlderMessages() async {
    if (_isLoading) return;
    
    setState(() => _isLoading = true);
    try {
      await _conversationProvider.fetchOlderMessages(
        context,
        widget.conversationId,
        limit: _messagesPerPage,
      );
      
      // Déchiffrer les nouveaux messages chargés
      await _conversationProvider.decryptVisibleMessages(
        widget.conversationId, 
        visibleCount: _visibleCount,
      );
      
    } catch (e) {
      debugPrint('❌ Erreur chargement messages anciens: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _onMessagesUpdated() {
    if (!_initialDecryptDone) return;
    
    // Auto-scroll seulement si l'utilisateur est en bas
    if (_isAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
    
    // Déchiffrer seulement les nouveaux messages visibles (optimisation)
    final messages = _conversationProvider.messagesFor(widget.conversationId);
    if (messages.isEmpty) return;
    
    // Utiliser la méthode optimisée de déchiffrement avec indicateur
    if (!_isDecrypting) {
      setState(() => _isDecrypting = true);
      _conversationProvider.decryptVisibleMessages(
        widget.conversationId,
        visibleCount: _visibleCount,
      ).then((_) {
        if (mounted) {
          setState(() => _isDecrypting = false);
        }
      });
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
    final target = _scrollController.position.maxScrollExtent;
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
                child: ListView(
                  controller: _scrollController,
                  reverse: false,
                  physics: const ClampingScrollPhysics(),
                  children: [
                    // Indicateur de chargement pour pagination (en haut de la liste)
                    if (_isLoading) 
                      const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    ...chatItems,
                  ],
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
          
          // Indicateur de déchiffrement en cours
          if (_isDecrypting)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Déchiffrement en cours...',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
