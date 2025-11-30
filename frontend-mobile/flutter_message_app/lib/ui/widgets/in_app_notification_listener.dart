import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/providers/group_provider.dart';
import '../../core/services/in_app_notification_service.dart';
import '../screens/conversation_screen.dart';
import '../screens/group_nav_screen.dart';

/// Widget qui écoute les changements des providers et affiche les notifications in-app
/// À placer dans les écrans principaux (HomeScreen, GroupConversationListScreen, etc.)
class InAppNotificationListener extends StatefulWidget {
  final Widget child;
  final String? currentGroupId;
  final String? currentGroupName;

  const InAppNotificationListener({
    Key? key,
    required this.child,
    this.currentGroupId,
    this.currentGroupName,
  }) : super(key: key);

  @override
  State<InAppNotificationListener> createState() => _InAppNotificationListenerState();
}

class _InAppNotificationListenerState extends State<InAppNotificationListener> {
  @override
  void initState() {
    super.initState();
    // Vérifier les notifications en attente après le premier frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingNotifications();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Écouter les changements des providers pour afficher les nouvelles notifications
    final convProvider = context.read<ConversationProvider>();
    final groupProvider = context.read<GroupProvider>();
    
    // Vérifier les notifications à chaque fois que les providers changent
    convProvider.addListener(_onProviderChanged);
    groupProvider.addListener(_onProviderChanged);
  }

  @override
  void dispose() {
    final convProvider = context.read<ConversationProvider>();
    final groupProvider = context.read<GroupProvider>();
    convProvider.removeListener(_onProviderChanged);
    groupProvider.removeListener(_onProviderChanged);
    super.dispose();
  }

  void _onProviderChanged() {
    if (mounted) {
      _checkPendingNotifications();
    }
  }

  void _checkPendingNotifications() {
    if (!mounted) return;

    // Vérifier les notifications de ConversationProvider
    final convProvider = context.read<ConversationProvider>();
    final convNotifications = convProvider.getPendingInAppNotifications();

    for (final notification in convNotifications) {
      if (!mounted) return;

      final type = notification['type'] as String;
      if (type == 'new_message') {
        final conversationId = notification['conversationId'] as String;
        final senderName = notification['senderName'] as String;
        final messageText = notification['messageText'] as String;

        InAppNotificationService.showNewMessageNotification(
          context: context,
          senderName: senderName,
          messageText: messageText,
          conversationId: conversationId,
          onTap: () {
            // Naviguer vers la conversation
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConversationScreen(conversationId: conversationId),
              ),
            );
          },
        );
      } else if (type == 'new_conversation') {
        final conversationId = notification['conversationId'] as String;
        final groupName = notification['groupName'] as String?;

        InAppNotificationService.showNewConversationNotification(
          context: context,
          conversationId: conversationId,
          groupName: groupName ?? widget.currentGroupName,
          onTap: () {
            // Naviguer vers la conversation
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConversationScreen(conversationId: conversationId),
              ),
            );
          },
        );
      }
    }

    // Vérifier les notifications de GroupProvider
    final groupProvider = context.read<GroupProvider>();
    final groupNotifications = groupProvider.getPendingInAppNotifications();

    for (final notification in groupNotifications) {
      if (!mounted) return;

      final type = notification['type'] as String;
      if (type == 'new_group') {
        final groupId = notification['groupId'] as String;
        final groupName = notification['groupName'] as String?;

        InAppNotificationService.showNewGroupNotification(
          context: context,
          groupId: groupId,
          groupName: groupName,
          onTap: () {
            // Trouver le groupe dans la liste et naviguer
            final groups = context.read<GroupProvider>().groups;
            try {
              final group = groups.firstWhere(
                (g) => g.groupId == groupId,
              );

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GroupNavScreen(
                    groupId: group.groupId,
                    groupName: group.name,
                  ),
                ),
              );
            } catch (e) {
              debugPrint('⚠️ Groupe $groupId non trouvé dans la liste');
            }
          },
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

