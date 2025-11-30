import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/models/group_info.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';
import 'dart:async';
import '../../core/services/websocket_service.dart';
import '../../core/services/websocket_heartbeat_service.dart';
import '../../core/services/network_monitor_service.dart';
import '../../core/services/notification_badge_service.dart';
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
            // Indicateur de statut WebSocket avec heartbeat
            _buildWebSocketStatusIndicator(),
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
            onTap: () {
              setState(() => _currentIndex = 0);
              // Réinitialiser le badge des nouveaux groupes quand on ouvre l'accueil
              NotificationBadgeService().setHasNewGroups(false);
            },
          ),
          NavTab(
            icon: Icons.shopping_bag_outlined,
            label: 'Boutique',
            onTap: () => setState(() => _currentIndex = 1),
          ),
          NavTab(
            icon: Icons.chat_bubble_outline,
            onTap: () {
              setState(() => _currentIndex = 2);
              // Réinitialiser le compteur de nouveaux messages quand on ouvre l'onglet Messages
              NotificationBadgeService().clearNewMessages();
            },
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
  
  /// Widget pour afficher le statut de connexion WebSocket avec heartbeat
  Widget _buildWebSocketStatusIndicator() {
    return _WebSocketStatusIndicatorWidget();
  }
}

/// Widget réutilisable pour l'indicateur de statut WebSocket
class _WebSocketStatusIndicatorWidget extends StatefulWidget {
  @override
  State<_WebSocketStatusIndicatorWidget> createState() => _WebSocketStatusIndicatorWidgetState();
}

class _WebSocketStatusIndicatorWidgetState extends State<_WebSocketStatusIndicatorWidget> {
  StreamSubscription<SocketStatus>? _wsStatusSubscription;
  StreamSubscription<HeartbeatState>? _heartbeatSubscription;
  SocketStatus _wsStatus = SocketStatus.disconnected;
  HeartbeatState? _heartbeatState;
  bool _hasNetwork = true;

  @override
  void initState() {
    super.initState();
    
    // Écouter le statut WebSocket
    _wsStatusSubscription = WebSocketService.instance.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _wsStatus = status;
        });
      }
    });
    
    // Écouter l'état du heartbeat
    final heartbeatService = WebSocketHeartbeatService();
    _heartbeatSubscription = heartbeatService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _heartbeatState = state;
        });
      }
    });
    
    // Écouter l'état du réseau
    NetworkMonitorService().networkStatusStream.listen((isConnected) {
      if (mounted) {
        setState(() {
          _hasNetwork = isConnected;
        });
      }
    });
    
    // Initialiser les valeurs
    _wsStatus = WebSocketService.instance.status;
    _heartbeatState = heartbeatService.currentState;
    _hasNetwork = NetworkMonitorService().isConnected;
  }

  @override
  void dispose() {
    _wsStatusSubscription?.cancel();
    _heartbeatSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final heartbeatService = WebSocketHeartbeatService();
    final isHealthy = _heartbeatState?.isConnectionHealthy ?? heartbeatService.isConnectionHealthy;
    
    // Déterminer la couleur selon l'état
    Color statusColor;
    String tooltip;
    
    if (!_hasNetwork) {
      statusColor = Colors.grey;
      tooltip = 'Pas de connexion réseau';
    } else if (_wsStatus == SocketStatus.connected) {
      if (isHealthy) {
        statusColor = Colors.green;
        tooltip = 'Connecté au serveur';
      } else {
        statusColor = Colors.orange;
        tooltip = 'Connexion instable';
      }
    } else if (_wsStatus == SocketStatus.connecting) {
      statusColor = Colors.orange;
      tooltip = 'Connexion en cours...';
    } else {
      statusColor = Colors.red;
      tooltip = 'Déconnecté';
    }
    
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: statusColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: statusColor.withOpacity(0.5),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

