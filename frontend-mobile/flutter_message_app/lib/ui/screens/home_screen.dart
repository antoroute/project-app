import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/models/group_info.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';
import '../../core/services/websocket_service.dart';
import '../../core/services/websocket_heartbeat_service.dart';
import '../../core/services/network_monitor_service.dart';
import '../../core/services/navigation_tracker_service.dart';
import '../../core/services/in_app_notification_service.dart';
import 'group_nav_screen.dart';
import 'group_screen.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    
    // Enregistrer l'écran actuel
    NavigationTrackerService().setCurrentScreen('HomeScreen');
    
    _loadData();
    
    // Vérifier les notifications en attente après le premier frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingNotifications();
    });
  }
  
  /// Vérifie et affiche les notifications in-app en attente
  void _checkPendingNotifications() {
    if (!mounted) return;
    
    final groupProvider = context.read<GroupProvider>();
    final notifications = groupProvider.getPendingInAppNotifications();
    
    for (final notification in notifications) {
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
            final group = groups.firstWhere(
              (g) => g.groupId == groupId,
              orElse: () => throw Exception('Group not found'),
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
          },
        );
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final List<GroupInfo> groups =
        Provider.of<GroupProvider>(context).groups;

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
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => GroupNavScreen(
                              groupId: g.groupId,
                              groupName: g.name,
                            ),
                          ),
                        ),
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
  
  /// Widget pour afficher le statut de connexion WebSocket avec heartbeat
  Widget _buildWebSocketStatusIndicator() {
    return StreamBuilder<SocketStatus>(
      stream: WebSocketService.instance.statusStream,
      builder: (context, snapshot) {
        final wsStatus = snapshot.data ?? SocketStatus.disconnected;
        final heartbeatService = WebSocketHeartbeatService();
        final isHealthy = heartbeatService.isConnectionHealthy;
        final networkService = NetworkMonitorService();
        final hasNetwork = networkService.isConnected;
        
        // Déterminer la couleur selon l'état
        Color statusColor;
        String tooltip;
        
        if (!hasNetwork) {
          statusColor = Colors.grey;
          tooltip = 'Pas de connexion réseau';
        } else if (wsStatus == SocketStatus.connected) {
          if (isHealthy) {
            statusColor = Colors.green;
            tooltip = 'Connecté au serveur';
          } else {
            statusColor = Colors.orange;
            tooltip = 'Connexion instable';
          }
        } else if (wsStatus == SocketStatus.connecting) {
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
      },
    );
  }
}
