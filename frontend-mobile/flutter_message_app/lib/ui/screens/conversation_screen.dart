import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/providers/auth_provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/models/message.dart';
import '../../core/crypto/message_cipher_v2.dart';
import '../../core/services/session_device_service.dart';
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

  static const int _messagesPerPage = 25;  // Messages chargés par pagination
  
  bool _isLoading = false;
  bool _initialDecryptDone = false;
  bool _hasMoreOlderMessages = true;
  
  // Timer pour les indicateurs de frappe
  Timer? _typingTimer;

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _conversationProvider = context.read<ConversationProvider>();

    // Pas d'écoute du scroll - géré par NotificationListener
    
    // WebSocket déjà connecté au niveau de l'app, juste s'abonner à la conversation
    _conversationProvider.subscribe(widget.conversationId);
    _conversationProvider.addListener(_onMessagesUpdated);

    _loadData();
  }

  /// Vérifie si l'utilisateur est proche du bas (reverse:true)
  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    return _scrollController.offset < 80.0; // reverse:true -> 0 == bas
  }

  /// Gestionnaire de notification de scroll pour reverse:true
  bool _onScrollNotification(ScrollNotification n) {
    // Near top de la liste inversée -> charger anciens
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 100 && _hasMoreOlderMessages) {
      _loadOlderPreservingOffset();
    }
    return false;
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
      
      // 5) Pré-charger les clés de groupe en arrière-plan
      _conversationProvider.preloadGroupKeys(widget.conversationId);
      
      // 6) Afficher immédiatement les messages [Chiffré] (non-bloquant)
      setState(() => _isLoading = false);
      
      // 7) Déchiffrement progressif en arrière-plan
      _startProgressiveDecryption();
      
      _initialDecryptDone = true;

    } catch (e) {
      debugPrint('❌ Erreur chargement conversation : $e');
      setState(() => _isLoading = false);
    }
  }

  /// Déchiffrement progressif en arrière-plan pour éviter le blocage de l'UI
  void _startProgressiveDecryption() {
    final messages = _conversationProvider.messagesFor(widget.conversationId);
    if (messages.isEmpty) return;
    
    // Déchiffrer les 3 derniers messages en premier (les plus importants)
    final lastMessages = messages.length > 3 
        ? messages.sublist(messages.length - 3)
        : messages;
    
    // Marquer les messages pour déchiffrement progressif
    for (int i = 0; i < lastMessages.length; i++) {
      Timer(Duration(milliseconds: i * 200), () {
        if (mounted) {
          // Déchiffrer directement sans notifyListeners()
          _decryptMessageDirectly(lastMessages[i]);
        }
      });
    }
  }
  
  /// Déchiffre un message directement sans déclencher de rebuild global
  Future<void> _decryptMessageDirectly(Message message) async {
    if (message.decryptedText != null) return; // Déjà déchiffré
    
    try {
      final currentUserId = context.read<AuthProvider>().userId;
      if (currentUserId == null) return;
      
      final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      
      // Déchiffrement direct sans passer par ConversationProvider
      final result = await MessageCipherV2.decryptFast(
        groupId: message.v2Data!['groupId'] as String,
        myUserId: currentUserId,
        myDeviceId: myDeviceId,
        messageV2: message.v2Data!,
        keyDirectory: _conversationProvider.keyDirectory,
      );
      
      final decryptedText = utf8.decode(result['decryptedText'] as Uint8List);
      message.signatureValid = false;
      message.decryptedText = decryptedText;
      
      // Mise à jour granulaire : seulement ce MessageBubble
      if (mounted) {
        setState(() {}); // Rebuild local seulement
      }
      
    } catch (e) {
      debugPrint('⚠️ Erreur déchiffrement direct message ${message.id}: $e');
      // Fallback sur le déchiffrement normal si nécessaire
      try {
        await _conversationProvider.decryptMessageIfNeeded(message);
      } catch (fallbackError) {
        debugPrint('❌ Erreur fallback déchiffrement message ${message.id}: $fallbackError');
      }
    }
  }

  /// Charge les messages plus anciens en préservant la position de scroll (reverse:true)
  Future<void> _loadOlderPreservingOffset() async {
    if (_isLoading || !_hasMoreOlderMessages) return;
    
    if (!_scrollController.hasClients) return;
    final before = _scrollController.position.maxScrollExtent;
    
    setState(() => _isLoading = true);
    try {
      final hasMore = await _conversationProvider.fetchOlderMessages(
        context,
        widget.conversationId,
        limit: _messagesPerPage,
      );
      
      // Arrêter le chargement s'il n'y a plus de messages
      if (!hasMore) {
        _hasMoreOlderMessages = false;
        debugPrint('📄 Plus de messages anciens à charger');
      }
      
      // Préserver la position de scroll après ajout des nouveaux messages
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final after = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(_scrollController.offset + (after - before)); // pas de "saut"
      });
    } catch (e) {
      debugPrint('❌ Erreur chargement messages anciens: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _onMessagesUpdated() {
    if (!_initialDecryptDone) return;
    
    // Auto-scroll seulement si l'utilisateur est proche du bas (reverse:true)
    if (_isNearBottom()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            0, // reverse:true -> bas
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      });
    } else {
      // Afficher un indicateur "Nouveaux messages" si pas en bas
      // TODO: Implémenter le pill "Nouveaux messages"
    }
  }

  Future<void> _onSendPressed() async {
    final plainText = _textController.text.trim();
    if (plainText.isEmpty) return;
    
    // Arrêter l'indicateur de frappe avant d'envoyer
    _conversationProvider.stopTyping(widget.conversationId);
    _typingTimer?.cancel();
    
    _textController.clear();
    await _conversationProvider.sendMessage(context, widget.conversationId, plainText);
  }
  
  /// Gère les événements de frappe
  void _onTextChanged(String text) {
    if (text.isNotEmpty) {
      // Démarrer l'indicateur de frappe
      _conversationProvider.startTyping(widget.conversationId);
      
      // Programmer l'arrêt de l'indicateur après 2 secondes d'inactivité
      _typingTimer?.cancel();
      _typingTimer = Timer(const Duration(seconds: 2), () {
        _conversationProvider.stopTyping(widget.conversationId);
      });
    } else {
      // Arrêter l'indicateur si le champ est vide
      _conversationProvider.stopTyping(widget.conversationId);
      _typingTimer?.cancel();
    }
  }
  
  /// Construit l'indicateur de frappe
  Widget _buildTypingIndicator() {
    final typingUsernames = _conversationProvider.getTypingUsernames(widget.conversationId);
    if (typingUsernames.isEmpty) return const SizedBox.shrink();
    
    // Filtrer notre propre utilisateur (comparer par pseudo)
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final currentUsername = authProvider.username ?? '';
    final otherTypingUsers = typingUsernames.where((username) => username != currentUsername).toList();
    
    if (otherTypingUsers.isEmpty) return const SizedBox.shrink();
    
    final typingText = otherTypingUsers.length == 1
        ? '${otherTypingUsers.first} est en train d\'écrire...'
        : '${otherTypingUsers.length} personnes sont en train d\'écrire...';
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        typingText,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _conversationProvider.unsubscribe(widget.conversationId);
    _conversationProvider.removeListener(_onMessagesUpdated);
    _textController.dispose();
    _scrollController.dispose();
    _typingTimer?.cancel(); // Annuler le timer de frappe
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = context
        .watch<ConversationProvider>()
        .messagesFor(widget.conversationId);
    
    // Si la liste est vide, ne rien afficher pour éviter le flash
    if (messages.isEmpty) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: Text(
                'Conversation',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
            _WebSocketStatusIndicator(),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      body: Column(
        children: [
          // Zone de messages avec NotificationListener
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: ListView.builder(
                reverse: true, // Clé anti-jump
                controller: _scrollController,
                itemCount: messages.length,
                itemBuilder: (_, i) {
                  final msg = messages[messages.length - 1 - i]; // dernier d'abord
                  final currentUserId = context.read<AuthProvider>().userId ?? '';
                  
                  // Calculer sameAsPrevious et sameAsNext pour l'affichage des vignettes
                  final sameAsPrevious = i < messages.length - 1 && 
                      messages[messages.length - 2 - i].senderId == msg.senderId;
                  final sameAsNext = i > 0 && 
                      messages[messages.length - i].senderId == msg.senderId;
                  
                  // Vérifier si on doit afficher un indicateur de date
                  final msgDate = DateTime.fromMillisecondsSinceEpoch(msg.timestamp * 1000).toLocal();
                  final dateOnly = DateTime(msgDate.year, msgDate.month, msgDate.day);
                  
                  // Vérifier la date du message précédent pour savoir si on doit afficher l'en-tête de date
                  DateTime? previousDate;
                  if (i < messages.length - 1) {
                    final prevMsg = messages[messages.length - 2 - i];
                    final prevMsgDate = DateTime.fromMillisecondsSinceEpoch(prevMsg.timestamp * 1000).toLocal();
                    previousDate = DateTime(prevMsgDate.year, prevMsgDate.month, prevMsgDate.day);
                  }
                  
                  final showDateHeader = previousDate == null || previousDate != dateOnly;
                  
                  return Column(
                    children: [
                      // Indicateur de date
                      if (showDateHeader)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Center(
                            child: Text(
                              dateOnly.toChatDateHeader(),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      
                      // Message
                      MessageBubble(
                        key: ValueKey(msg.id), // Clé stable
                        isMe: msg.senderId == currentUserId,
                        text: msg.decryptedText ?? '[Chiffré]',
                        time: msgDate.toHm(),
                        signatureValid: msg.signatureValid,
                        senderInitial: msg.senderId == currentUserId ? '' : msg.senderId[0].toUpperCase(),
                        senderUsername: context.read<ConversationProvider>().getUsernameForUser(msg.senderId),
                        senderUserId: msg.senderId,
                        conversationId: widget.conversationId,
                        sameAsPrevious: sameAsPrevious,
                        sameAsNext: sameAsNext,
                        maxWidth: context.maxBubbleWidth,
                        messageId: msg.id,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          // Zone de saisie avec SafeArea pour Android
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Indicateur de frappe
                  _buildTypingIndicator(),
                  
                  // Zone de saisie
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          onChanged: _onTextChanged,
                          decoration: InputDecoration(
                            hintText: 'Tapez votre message...',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(20),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surfaceVariant,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          maxLines: 4,
                          minLines: 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FloatingActionButton(
                        onPressed: _onSendPressed,
                        mini: true,
                        child: const Icon(Icons.send),
                      ),
                    ],
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

/// Widget pour afficher le statut de connexion WebSocket
class _WebSocketStatusIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: Colors.green, // Simplifié pour l'instant
        shape: BoxShape.circle,
      ),
    );
  }
}
