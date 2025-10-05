import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/providers/conversation_provider.dart';

/// Dimensions partagées pour le chat
class ChatStyles {
  static const bubbleRadius = Radius.circular(15);
  static const bubblePadding = EdgeInsets.symmetric(vertical: 3, horizontal: 12);
  static const double avatarDiameter = 36;
  static const double avatarSpacing = 46;  
}

class MessageBubble extends StatelessWidget {
  final bool isMe;
  final String text;
  final String? time;
  final bool signatureValid;
  final String senderInitial;
  final String senderUsername;
  final String? senderUserId; // Ajout pour les indicateurs de présence
  final bool sameAsPrevious;
  final bool sameAsNext;
  final double maxWidth;

  const MessageBubble({
    Key? key,
    required this.isMe,
    required this.text,
    this.time,
    required this.signatureValid,
    required this.senderInitial,
    this.senderUsername = '',
    this.senderUserId, // Nouveau paramètre
    this.sameAsPrevious = false,
    this.sameAsNext = false,
    required this.maxWidth,
  }) : super(key: key);

  /// Avatar ou espace réservé avec indicateur de présence
  Widget _avatarOrSpacer(BuildContext context) {
    final theme = Theme.of(context);
    if (isMe || sameAsNext) {
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
                senderUsername.isNotEmpty
                    ? senderUsername[0].toUpperCase()
                    : senderInitial,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
          // Indicateur de présence
          if (senderUserId != null && !isMe)
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
        final isOnline = provider.isUserOnline(senderUserId!);
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
        isMe ? theme.colorScheme.primary : theme.colorScheme.secondary;
    final messageStyle = theme.textTheme.bodyLarge!;
    final timeStyle = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSecondary,
    );
    final usernameStyle = messageStyle.copyWith(
      fontWeight: FontWeight.bold,
      color: theme.colorScheme.onSecondary,
      fontSize: 13,
    );

    final iconData = signatureValid ? Icons.verified : Icons.warning_amber;
    final iconColor = signatureValid
        ? theme.colorScheme.onError
        : theme.colorScheme.error;
    final tooltipMsg = signatureValid
        ? 'Signature vérifiée : message signé par l’expéditeur.'
        : 'Signature non vérifiée : le message a pu être altéré.';
    final showIcon = (!sameAsNext && !isMe) || !signatureValid;

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        // optional username
        if (!isMe && !sameAsPrevious)
          Padding(
            padding: const EdgeInsets.only(left: 58),
            child: Text(senderUsername, style: usernameStyle),
          ),

        // bubble + avatar 
        Row(
          mainAxisAlignment:
              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // avatar ou espace
            _avatarOrSpacer(context),

            // la bulle
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Container(
                  padding: ChatStyles.bubblePadding,
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.only(
                      topLeft: ChatStyles.bubbleRadius,
                      topRight: ChatStyles.bubbleRadius,
                      bottomLeft:
                          isMe ? ChatStyles.bubbleRadius : Radius.zero,
                      bottomRight:
                          isMe ? Radius.zero : ChatStyles.bubbleRadius,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: isMe
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(text, style: messageStyle),
                      if (time != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 0),
                          child: Text(time!, style: timeStyle),
                        ),
                    ],
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

        const SizedBox(height: 2),
      ],
    );
  }
}
