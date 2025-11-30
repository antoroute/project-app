import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../themes/app_colors.dart';
import '../../core/services/notification_badge_service.dart';

/// Onglet de navigation avec icône et label optionnel
class NavTab {
  final IconData icon;
  final String? label;
  final VoidCallback onTap;

  const NavTab({
    required this.icon,
    this.label,
    required this.onTap,
  });
}

/// Barre de navigation en bas avec 5 onglets
/// Les 4 premiers sont alignés, le 5ème est décentré au centre
class BottomNavBar extends StatefulWidget {
  final int currentIndex;
  final List<NavTab> tabs;
  final int centerTabIndex; // Index du tab décentré (par défaut 2, le 3ème)
  final String? currentGroupId; // ID du groupe actuel (pour filtrer les badges)

  const BottomNavBar({
    Key? key,
    required this.currentIndex,
    required this.tabs,
    this.centerTabIndex = 2,
    this.currentGroupId,
  }) : super(key: key);

  @override
  State<BottomNavBar> createState() => _BottomNavBarState();
}

class _BottomNavBarState extends State<BottomNavBar> {
  // Pas besoin d'AnimationController pour les onglets simples,
  // on utilise AnimatedContainer qui gère l'animation automatiquement

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    // Couleur de fond légèrement différente pour se démarquer
    final backgroundColor = isDark 
        ? AppColors.grey[700] // Plus clair que grey[900] pour se démarquer
        : AppColors.grey[50]; // Légèrement grisé en mode clair

    // Obtenir le padding de la barre de navigation système Android
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return ChangeNotifierProvider.value(
      value: NotificationBadgeService(),
      child: Container(
        padding: EdgeInsets.only(bottom: bottomPadding),
        decoration: BoxDecoration(
          color: backgroundColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SizedBox(
          height: 60,
          child: Stack(
            clipBehavior: Clip.none, // Permettre au badge de dépasser sans être tronqué
            children: [
              // Les 4 premiers onglets alignés répartis uniformément
              // (tous sauf celui à centerTabIndex)
              Consumer<NotificationBadgeService>(
                builder: (context, badgeService, child) {
                  return Row(
                    children: [
                      // Afficher les onglets 0, 1, 2, 3 (sauf celui à centerTabIndex)
                      for (int i = 0; i < widget.tabs.length; i++)
                        if (i != widget.centerTabIndex) ...[
                          Expanded(
                            child: _buildTab(
                              index: i,
                              isSelected: widget.currentIndex == i,
                              theme: theme,
                              isDark: isDark,
                              badgeService: badgeService,
                            ),
                          ),
                          // Ajouter un espacement après les 2 premiers onglets
                          // pour éloigner du centre
                          if (i == 1) const SizedBox(width: 30),
                        ],
                    ],
                  );
                },
              ),
              // Tab central décentré vers le haut avec encadré
              Positioned(
                left: 0,
                right: 0,
                top: -8, // Décalage vers le haut pour le tab central
                child: Center(
                  child: Consumer<NotificationBadgeService>(
                    builder: (context, badgeService, child) {
                      return _buildCenterTab(
                        isSelected: widget.currentIndex == widget.centerTabIndex,
                        theme: theme,
                        badgeService: badgeService,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTab({
    required int index,
    required bool isSelected,
    required ThemeData theme,
    required bool isDark,
    NotificationBadgeService? badgeService,
  }) {
    if (index >= widget.tabs.length) {
      return const SizedBox.shrink();
    }

    final tab = widget.tabs[index];
    final color = isSelected
        ? (isDark ? AppColors.blue[300] : AppColors.blue[500])
        : (isDark ? AppColors.grey[400] : AppColors.grey[600]);

    // Badge pour nouveaux messages : afficher sur l'onglet Messages
    // Dans group_nav_screen : index 0 (Messages avec Icons.message_outlined)
    // Dans main_nav_screen : index 2 (Messages avec Icons.chat_bubble_outline) mais c'est le tab central
    // On détecte l'onglet Messages par son icône
    final isMessagesTab = tab.icon == Icons.message_outlined || 
                         tab.icon == Icons.chat_bubble_outline;
    // Afficher le badge seulement si ce n'est PAS le tab central (car le tab central est géré séparément)
    // Si on est dans un groupe (currentGroupId != null), afficher seulement les updates de ce groupe (messages + nouvelles conversations)
    final updatesCount = widget.currentGroupId != null
        ? (badgeService?.getUpdatesCountForGroup(widget.currentGroupId!) ?? 0)
        : (badgeService?.newMessagesCount ?? 0);
    final showMessagesBadge = isMessagesTab && 
                             index != widget.centerTabIndex && 
                             updatesCount > 0;

    return GestureDetector(
      onTap: tab.onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Container pour garantir la même taille et alignement pour tous les icônes
            Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      transform: Matrix4.identity()
                        ..scale(isSelected ? 1.15 : 1.0),
                      child: Icon(
                        tab.icon,
                        color: color,
                        size: 24,
                      ),
                    ),
                  ),
                ),
                // Badge pour nouveaux messages sur l'onglet Messages
                if (showMessagesBadge)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 16,
                        minHeight: 16,
                      ),
                      child: Text(
                        updatesCount > 99 
                            ? '99+' 
                            : '$updatesCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            if (tab.label != null) ...[
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  color: color,
                  fontSize: isSelected ? 11 : 10,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
                child: Text(tab.label!),
              ),
            ] else ...[
              // Espace pour les onglets sans label pour maintenir l'alignement
              const SizedBox(height: 4),
              const SizedBox(height: 10), // Hauteur approximative du texte
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCenterTab({
    required bool isSelected,
    required ThemeData theme,
    NotificationBadgeService? badgeService,
  }) {
    if (widget.centerTabIndex >= widget.tabs.length) {
      return const SizedBox.shrink();
    }

    final tab = widget.tabs[widget.centerTabIndex];
    final isDark = theme.brightness == Brightness.dark;
    
    // Badge pour nouveaux groupes OU nouveaux messages selon le tab central
    // Dans group_nav_screen : centerTabIndex == 4 (Retour home) -> badge AUTRES groupes avec updates
    // Dans main_nav_screen : centerTabIndex == 2 (Messages) -> badge messages
    final isHomeTab = tab.icon == Icons.home;
    final isMessagesTab = tab.icon == Icons.chat_bubble_outline;
    
    // Pour l'icône home dans group_nav_screen, afficher un badge si des AUTRES groupes ont des updates
    final otherGroupsUpdatesCount = widget.currentGroupId != null
        ? (badgeService?.getOtherGroupsUpdatesCount(widget.currentGroupId!) ?? 0)
        : 0;
    final showNewGroupsBadge = isHomeTab && otherGroupsUpdatesCount > 0;
    final showNewMessagesBadge = isMessagesTab && (badgeService?.newMessagesCount ?? 0) > 0;
    final showBadge = showNewGroupsBadge || showNewMessagesBadge;

    return GestureDetector(
      onTap: tab.onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            width: isSelected ? 50 : 46,
            height: isSelected ? 50 : 46,
            decoration: BoxDecoration(
              // Carré gris avec coins arrondis (assombri)
              color: isDark ? AppColors.grey[600] : AppColors.grey[400],
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                width: isSelected ? 28 : 24,
                height: isSelected ? 28 : 24,
                decoration: BoxDecoration(
                  // Rond vide (cercle avec bordure) au centre
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected 
                        ? AppColors.purple[400]! 
                        : AppColors.purple[300]!,
                    width: isSelected ? 3 : 2.5,
                  ),
                ),
              ),
            ),
          ),
          // Badge pour nouveaux groupes ou nouveaux messages sur le tab central
          // CORRECTION: Positionner le badge plus haut et à droite pour éviter la troncature
          if (showBadge)
            Positioned(
              right: -1,
              top: -8,
              child: showNewMessagesBadge
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                      child: Text(
                        (badgeService?.newMessagesCount ?? 0) > 99 
                            ? '99+' 
                            : '${badgeService?.newMessagesCount ?? 0}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : showNewGroupsBadge
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 18,
                            minHeight: 18,
                          ),
                          child: Text(
                            otherGroupsUpdatesCount > 99 
                                ? '99+' 
                                : '$otherGroupsUpdatesCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                        ),
            ),
        ],
      ),
    );
  }
}

