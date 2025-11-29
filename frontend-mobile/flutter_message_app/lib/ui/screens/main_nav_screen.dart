import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/models/group_info.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';
import '../../core/services/websocket_service.dart';
import '../widgets/bottom_nav_bar.dart';
import 'group_conversation_list.dart';
import 'group_screen.dart';
import 'login_screen.dart';

/// Écran principal avec navigation bar
/// Le premier onglet affiche la liste des groupes
class MainNavScreen extends StatefulWidget {
  final String? initialGroupId;
  final String? initialGroupName;

  const MainNavScreen({
    Key? key,
    this.initialGroupId,
    this.initialGroupName,
  }) : super(key: key);

  @override
  State<MainNavScreen> createState() => _MainNavScreenState();
}

class _MainNavScreenState extends State<MainNavScreen> {
  int _currentIndex = 0;
  String? _selectedGroupId;
  String? _selectedGroupName;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _selectedGroupId = widget.initialGroupId;
    _selectedGroupName = widget.initialGroupName;
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      await Provider.of<GroupProvider>(context, listen: false)
          .fetchUserGroups();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur chargement : $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    await Provider.of<AuthProvider>(context, listen: false).logout();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  void _onGroupSelected(GroupInfo group) {
    setState(() {
      _selectedGroupId = group.groupId;
      _selectedGroupName = group.name;
      _currentIndex = 0; // Revenir au premier onglet
    });
  }

  Widget _buildGroupListScreen() {
    final List<GroupInfo> groups =
        Provider.of<GroupProvider>(context).groups;

    // Si un groupe est sélectionné, afficher la liste des conversations
    if (_selectedGroupId != null && _selectedGroupName != null) {
      return GroupConversationListScreen(
        groupId: _selectedGroupId!,
        groupName: _selectedGroupName!,
        bottomNavigationBar: BottomNavBar(
          currentIndex: _currentIndex,
          tabs: [
            NavTab(
              icon: Icons.home_outlined,
              label: 'Accueil',
              onTap: () => setState(() => _currentIndex = 0),
            ),
            NavTab(
              icon: Icons.shopping_bag_outlined,
              label: 'Boutique',
              onTap: () => setState(() => _currentIndex = 1),
            ),
            NavTab(
              icon: Icons.chat_bubble_outline,
              onTap: () => setState(() => _currentIndex = 2),
            ),
            NavTab(
              icon: Icons.grid_view_outlined,
              label: 'Grille',
              onTap: () => setState(() => _currentIndex = 3),
            ),
            NavTab(
              icon: Icons.person_outline,
              label: 'Profil',
              onTap: () => setState(() => _currentIndex = 4),
            ),
          ],
          centerTabIndex: 2,
        ),
      );
    }

    // Sinon, afficher la liste des groupes
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Mes Groupes'),
            const SizedBox(width: 8),
            // Indicateur de statut WebSocket
            StreamBuilder<SocketStatus>(
              stream: WebSocketService.instance.statusStream,
              builder: (context, snapshot) {
                final status = snapshot.data ?? SocketStatus.disconnected;
                return Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: status == SocketStatus.connected 
                        ? Colors.green 
                        : status == SocketStatus.connecting 
                            ? Colors.orange 
                            : Colors.red,
                  ),
                );
              },
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
            tooltip: 'Se déconnecter',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : groups.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const <Widget>[
                      SizedBox(height: 200),
                      Center(child: Text('Aucun groupe trouvé')),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final GroupInfo g = groups[index];
                      return ListTile(
                        title: Text(g.name),
                        onTap: () => _onGroupSelected(g),
                      );
                    },
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final bool? created = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const GroupScreen()),
          );
          if (created == true) {
            _loadData();
          }
        },
        child: const Icon(Icons.group_add),
        tooltip: 'Créer / Rejoindre un groupe',
      ),
    );
  }

  Widget _buildPlaceholderScreen(String title, IconData icon) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Cette fonctionnalité sera bientôt disponible',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Liste des écrans correspondant aux onglets
    final List<Widget> _screens = [
      _buildGroupListScreen(),
      _buildPlaceholderScreen('Boutique', Icons.shopping_bag_outlined),
      _buildPlaceholderScreen('Chat', Icons.chat_bubble_outline),
      _buildPlaceholderScreen('Grille', Icons.grid_view_outlined),
      _buildPlaceholderScreen('Profil', Icons.person_outline),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavBar(
        currentIndex: _currentIndex,
        tabs: [
          NavTab(
            icon: Icons.home_outlined,
            label: 'Accueil',
            onTap: () => setState(() => _currentIndex = 0),
          ),
          NavTab(
            icon: Icons.shopping_bag_outlined,
            label: 'Boutique',
            onTap: () => setState(() => _currentIndex = 1),
          ),
          NavTab(
            icon: Icons.chat_bubble_outline,
            onTap: () => setState(() => _currentIndex = 2),
          ),
          NavTab(
            icon: Icons.grid_view_outlined,
            label: 'Grille',
            onTap: () => setState(() => _currentIndex = 3),
          ),
          NavTab(
            icon: Icons.person_outline,
            label: 'Profil',
            onTap: () => setState(() => _currentIndex = 4),
          ),
        ],
        centerTabIndex: 2, // Le 3ème onglet (index 2) est décentré
      ),
    );
  }
}

