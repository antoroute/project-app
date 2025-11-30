import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/providers/group_provider.dart';

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
        // CORRECTION: Ne plus afficher de notification texte pour les nouveaux messages
        // Les badges suffisent pour indiquer qu'il y a de nouveaux messages
        debugPrint('🔔 [InAppNotificationListener] Nouveau message détecté (badge uniquement, pas de notification texte)');
      } else if (type == 'new_conversation') {
        // CORRECTION: Ne plus afficher de notification texte pour les nouvelles conversations
        // Les badges suffisent pour indiquer qu'il y a une nouvelle conversation
        debugPrint('🔔 [InAppNotificationListener] Nouvelle conversation détectée (badge uniquement, pas de notification texte)');
      }
    }

    // Vérifier les notifications de GroupProvider
    final groupProvider = context.read<GroupProvider>();
    final groupNotifications = groupProvider.getPendingInAppNotifications();

    for (final notification in groupNotifications) {
      if (!mounted) return;

      final type = notification['type'] as String;
      if (type == 'new_group') {
        // CORRECTION: Ne plus afficher de notification texte pour les nouveaux groupes
        // Les badges suffisent pour indiquer qu'il y a un nouveau groupe
        debugPrint('🔔 [InAppNotificationListener] Nouveau groupe détecté (badge uniquement, pas de notification texte)');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

