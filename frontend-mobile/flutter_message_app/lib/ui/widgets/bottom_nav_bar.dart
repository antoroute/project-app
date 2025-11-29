import 'package:flutter/material.dart';
import '../themes/app_colors.dart';

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

  const BottomNavBar({
    Key? key,
    required this.currentIndex,
    required this.tabs,
    this.centerTabIndex = 2,
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

    return Container(
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
        children: [
          // Les 4 premiers onglets alignés répartis uniformément
          // (tous sauf celui à centerTabIndex)
          Row(
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
                    ),
                  ),
                  // Ajouter un espacement après les 2 premiers onglets (Messages et Calendrier)
                  // pour éloigner du centre
                  if (i == 1) const SizedBox(width: 30),
                ],
            ],
          ),
          // Tab central décentré vers le haut avec encadré
          Positioned(
            left: 0,
            right: 0,
            top: -8, // Décalage vers le haut pour le tab central
            child: Center(
              child: _buildCenterTab(
                isSelected: widget.currentIndex == widget.centerTabIndex,
                theme: theme,
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildTab({
    required int index,
    required bool isSelected,
    required ThemeData theme,
    required bool isDark,
  }) {
    if (index >= widget.tabs.length) {
      return const SizedBox.shrink();
    }

    final tab = widget.tabs[index];
    final color = isSelected
        ? (isDark ? AppColors.blue[300] : AppColors.blue[500])
        : (isDark ? AppColors.grey[400] : AppColors.grey[600]);

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
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              width: 24,
              height: 24,
              transform: Matrix4.identity()
                ..scale(isSelected ? 1.15 : 1.0),
              alignment: Alignment.center,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Icon(
                  tab.icon,
                  color: color,
                  size: 24,
                ),
              ),
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
  }) {
    if (widget.centerTabIndex >= widget.tabs.length) {
      return const SizedBox.shrink();
    }

    final tab = widget.tabs[widget.centerTabIndex];
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      onTap: tab.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
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
    );
  }
}

