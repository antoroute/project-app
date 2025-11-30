import 'package:flutter/material.dart';
import '../widgets/bottom_nav_bar.dart';
import 'group_conversation_list.dart';
import 'group_calendar_screen.dart';
import 'group_map_screen.dart';
import 'group_detail_info_screen.dart';
import 'home_screen.dart';

/// Écran wrapper avec navigation bar pour un groupe sélectionné
class GroupNavScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupNavScreen({
    Key? key,
    required this.groupId,
    required this.groupName,
  }) : super(key: key);

  @override
  State<GroupNavScreen> createState() => _GroupNavScreenState();
}

class _GroupNavScreenState extends State<GroupNavScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    // CORRECTION: Ne pas nettoyer les badges quand on arrive sur la liste des conversations
    // Les badges seront nettoyés seulement quand on ouvre une conversation spécifique
    // Cela permet à l'utilisateur de voir quelles conversations ont des updates
    
    // Liste des écrans correspondant aux onglets
    final List<Widget> screens = [
      // Onglet 1 : Messages (conversations)
      GroupConversationListScreen(
        groupId: widget.groupId,
        groupName: widget.groupName,
      ),
      // Onglet 2 : Calendrier
      GroupCalendarScreen(
        groupId: widget.groupId,
        groupName: widget.groupName,
      ),
      // Onglet 3 : Map (placeholder pour l'instant)
      GroupMapScreen(
        groupId: widget.groupId,
        groupName: widget.groupName,
      ),
      // Onglet 4 : Détails du groupe
      GroupDetailInfoScreen(
        groupId: widget.groupId,
        groupName: widget.groupName,
      ),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: BottomNavBar(
        currentIndex: _currentIndex,
        currentGroupId: widget.groupId, // Passer le groupId pour filtrer les badges
        tabs: [
          // Onglet 1 : Messages
          NavTab(
            icon: Icons.message_outlined,
            label: 'Messages',
            onTap: () => setState(() => _currentIndex = 0),
          ),
          // Onglet 2 : Calendrier
          NavTab(
            icon: Icons.calendar_today_outlined,
            label: 'Calendrier',
            onTap: () => setState(() => _currentIndex = 1),
          ),
          // Onglet 3 : Map (affiche l'écran Map)
          NavTab(
            icon: Icons.map_outlined,
            label: 'Carte',
            onTap: () => setState(() => _currentIndex = 2),
          ),
          // Onglet 4 : Détails groupe
          NavTab(
            icon: Icons.info_outline,
            label: 'Infos',
            onTap: () => setState(() => _currentIndex = 3),
          ),
          // Onglet 5 : Retour à home (cercle central)
          NavTab(
            icon: Icons.home,
            onTap: () {
              // Retourner à home_screen.dart
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const HomeScreen()),
                (route) => false,
              );
            },
          ),
        ],
        centerTabIndex: 4, // Le 5ème onglet (Retour home) est décentré
      ),
    );
  }
}

