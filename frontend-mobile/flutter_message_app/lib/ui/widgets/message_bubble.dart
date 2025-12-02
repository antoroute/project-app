import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/providers/conversation_provider.dart';

/// Dimensions partagées pour le chat
class ChatStyles {
  static const bubbleRadius = Radius.circular(15);
  static const bubblePadding = EdgeInsets.symmetric(vertical: 3, horizontal: 12);
  static const double avatarDiameter = 36;
  static const double avatarSpacing = 46;
  static const double messageSpacing = 4;
}

class MessageBubble extends StatefulWidget {
  final bool isMe;
  final String text;
  final String? time;
  final bool signatureValid;
  final String senderInitial;
  final String senderUsername;
  final String? senderUserId; // Ajout pour les indicateurs de présence
  final String? conversationId; // Ajout pour la présence spécifique aux conversations
  final bool sameAsPrevious;
  final bool sameAsNext;
  final double maxWidth;
  final String? messageId; // NOUVEAU: ID du message pour le déchiffrement lazy

  const MessageBubble({
    super.key,
    required this.isMe,
    required this.text,
    this.time,
    required this.signatureValid,
    required this.senderInitial,
    this.senderUsername = '',
    this.senderUserId, // Nouveau paramètre
    this.conversationId, // Nouveau paramètre pour la présence spécifique
    this.sameAsPrevious = false,
    this.sameAsNext = false,
    required this.maxWidth,
    this.messageId, // NOUVEAU: ID du message pour le déchiffrement lazy
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _hasDecrypted = false;
  String _currentText = '';

  /// Copie le texte du message dans le presse-papiers
  Future<void> _copyMessage() async {
    if (_currentText.isEmpty || _currentText == '[Chiffré]') {
      return; // Ne pas copier les messages non déchiffrés
    }
    
    try {
      // Feedback haptique
      HapticFeedback.lightImpact();
      
      await Clipboard.setData(ClipboardData(text: _currentText));
    } catch (e) {
      debugPrint('❌ Erreur lors de la copie: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _currentText = widget.text;
    
    // CORRECTION: Déchiffrement seulement si le message n'est pas déjà déchiffré ET pas dans les 15 premiers
    if (widget.text == '[Chiffré]' && widget.messageId != null && widget.conversationId != null) {
      _decryptMessageUltraGradual();
    }
  }

  @override
  void didUpdateWidget(covariant MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    final textChanged = widget.text != oldWidget.text;
    final idChanged = widget.messageId != oldWidget.messageId;

    if (idChanged) {
      // Nouveau message: resynchroniser l'état
      _hasDecrypted = false;
      _currentText = widget.text;
      if (widget.text == '[Chiffré]' && widget.messageId != null && widget.conversationId != null) {
        _decryptMessageUltraGradual();
      }
      setState(() {}); // refléter immédiatement
      return;
    }

    if (textChanged && widget.text != _currentText) {
      _currentText = widget.text;
      setState(() {}); // met à jour l'affichage quand decryptedText arrive
      if (_currentText == '[Chiffré]' && !_hasDecrypted && widget.messageId != null && widget.conversationId != null) {
        _decryptMessageUltraGradual();
      }
    }
  }

  /// Déchiffre le message de manière ultra-graduelle pour éviter complètement le freeze
  Future<void> _decryptMessageUltraGradual() async {
    if (_hasDecrypted || widget.messageId == null || widget.conversationId == null) return;
    
    // CORRECTION: Vérifier d'abord si le message est déjà déchiffré dans le cache
    try {
      final provider = context.read<ConversationProvider>();
      final messages = provider.messagesFor(widget.conversationId!);
      final message = messages.firstWhere(
        (m) => m.id == widget.messageId,
        orElse: () => throw Exception('Message not found'),
      );
      
      // Si le message est déjà déchiffré, l'utiliser directement
      if (message.decryptedText != null && message.decryptedText!.isNotEmpty) {
        if (mounted) {
          setState(() {
            _currentText = message.decryptedText!;
          });
        }
        return;
      }
    } catch (e) {
      debugPrint('❌ Erreur vérification cache pour message ${widget.messageId}: $e');
    }
    
    _hasDecrypted = true;
    
    try {
      final provider = context.read<ConversationProvider>();
      final messages = provider.messagesFor(widget.conversationId!);
      final message = messages.firstWhere(
        (m) => m.id == widget.messageId,
        orElse: () => throw Exception('Message not found'),
      );
      
      // CORRECTION: Déchiffrement automatique intelligent - seulement si nécessaire
      final messageIndex = messages.indexOf(message);
      final totalMessages = messages.length;
      
      // Ne pas déchiffrer automatiquement les messages déjà déchiffrés
      if (message.decryptedText != null) {
        return;
      }
      
      // CORRECTION: Déchiffrement automatique avec délais très courts pour mobile
      int delayMs;
      if (messageIndex >= totalMessages - 3) {
        delayMs = 0; // 3 derniers messages : immédiat (déjà gérés par decryptVisibleMessagesFast)
      } else if (messageIndex >= totalMessages - 6) {
        delayMs = 10; // Messages récents : très court
      } else if (messageIndex >= totalMessages - 10) {
        delayMs = 20; // Messages moyens : court
      } else {
        delayMs = 50; // Messages anciens : délai raisonnable
      }
      
      // Attendre le délai calculé
      await Future.delayed(Duration(milliseconds: delayMs));
      
      // Déchiffrer le message
      final decryptedText = await provider.decryptMessageIfNeeded(message);
      
      if (mounted && decryptedText != null) {
        setState(() {
          _currentText = decryptedText;
        });
      }
    } catch (e) {
      debugPrint('❌ Erreur déchiffrement ultra-graduel pour message ${widget.messageId}: $e');
      if (mounted) {
        setState(() {
          _currentText = '[Erreur déchiffrement]';
        });
      }
    }
  }

  /// Avatar ou espace réservé avec indicateur de présence
  Widget _avatarOrSpacer(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.isMe || widget.sameAsNext) {
      return const SizedBox(width: ChatStyles.avatarSpacing);
    }
    
    return SizedBox(
      width: ChatStyles.avatarSpacing,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.bottomCenter,
            child: CircleAvatar(
              radius: ChatStyles.avatarDiameter / 2,
              backgroundColor: theme.colorScheme.tertiary,  
              child: Text(
                widget.senderUsername.isNotEmpty
                    ? widget.senderUsername[0].toUpperCase()
                    : widget.senderInitial,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
          // Indicateur de présence
          if (widget.senderUserId != null && !widget.isMe)
            Positioned(
              bottom: 0,
              right: 0,
              child: _buildPresenceIndicator(context),
            ),
        ],
      ),
    );
  }
  
  /// Indicateur de présence (cercle vert/gris)
  Widget _buildPresenceIndicator(BuildContext context) {
    return Consumer<ConversationProvider>(
      builder: (context, provider, _) {
        // Utiliser la présence spécifique aux conversations si disponible, sinon la présence générale
        final isOnline = widget.conversationId != null 
            ? provider.isUserOnlineInConversation(widget.conversationId!, widget.senderUserId!)
            : provider.isUserOnline(widget.senderUserId!);
            
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isOnline ? Colors.green : Colors.grey.shade400,
            border: Border.all(color: Colors.white, width: 2),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbleColor =
        widget.isMe ? theme.colorScheme.primary : theme.colorScheme.secondary;
    final messageStyle = theme.textTheme.bodyLarge!;
    final timeStyle = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSecondary,
    );
    final usernameStyle = messageStyle.copyWith(
      fontWeight: FontWeight.bold,
      color: theme.colorScheme.onSecondary,
      fontSize: 13,
    );

    final iconData = widget.signatureValid ? Icons.verified : Icons.warning_amber;
    final iconColor = widget.signatureValid
        ? theme.colorScheme.onError
        : theme.colorScheme.error;
    final tooltipMsg = widget.signatureValid
        ? 'Signature verifiee : message signe par l\'expediteur.'
        : 'Signature non verifiee : le message a pu etre altere.';
    final showIcon = (!widget.sameAsNext && !widget.isMe) || !widget.signatureValid;

    return Column(
      crossAxisAlignment:
          widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        // optional username
        if (!widget.isMe && !widget.sameAsPrevious)
          Padding(
            padding: const EdgeInsets.only(left: 58),
            child: Text(widget.senderUsername, style: usernameStyle),
          ),

        // bubble + avatar 
        Row(
          mainAxisAlignment:
              widget.isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // avatar ou espace
            _avatarOrSpacer(context),

            // la bulle avec gestion d'overflow et copie longue pression
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.maxWidth),
                child: GestureDetector(
                  onLongPress: _copyMessage,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.only(
                        topLeft: ChatStyles.bubbleRadius,
                        topRight: ChatStyles.bubbleRadius,
                        bottomLeft:
                            widget.isMe ? ChatStyles.bubbleRadius : Radius.zero,
                        bottomRight:
                            widget.isMe ? Radius.zero : ChatStyles.bubbleRadius,
                      ),
                      onTap: () {
                        // Feedback léger au tap pour indiquer l'interactivité
                        HapticFeedback.selectionClick();
                      },
                      child: Container(
                        padding: ChatStyles.bubblePadding,
                        decoration: BoxDecoration(
                          color: bubbleColor,
                          borderRadius: BorderRadius.only(
                            topLeft: ChatStyles.bubbleRadius,
                            topRight: ChatStyles.bubbleRadius,
                            bottomLeft:
                                widget.isMe ? ChatStyles.bubbleRadius : Radius.zero,
                            bottomRight:
                                widget.isMe ? Radius.zero : ChatStyles.bubbleRadius,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: widget.isMe
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Texte avec gestion d'overflow
                            Text(
                              _currentText, // CORRECTION: Utiliser le texte déchiffré
                              style: messageStyle.copyWith(
                                height: 1.4,
                                letterSpacing: 0.1,
                              ),
                              overflow: TextOverflow.visible,
                              softWrap: true,
                            ),
                            if (widget.time != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      widget.time!,
                                      style: timeStyle.copyWith(
                                        fontSize: 11,
                                        letterSpacing: 0.2,
                                      ),
                                      overflow: TextOverflow.visible,
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),

        // signature en dessous
        if (showIcon)
          Padding(
            padding: const EdgeInsets.only(
              left: ChatStyles.avatarSpacing + 4,
              top: 4,
            ),
            child: Tooltip(
              message: tooltipMsg,
              triggerMode: TooltipTriggerMode.tap,
              showDuration: const Duration(seconds: 2),
              preferBelow: false,
              child: Icon(iconData, size: 14, color: iconColor),
            ),
          ),

        SizedBox(height: ChatStyles.messageSpacing),
      ],
    );
  }
}
