import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/models/group_info.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';
import '../../core/providers/conversation_provider.dart';
import 'dart:async';
import '../../core/services/websocket_service.dart';
import '../../core/services/websocket_heartbeat_service.dart';
import '../../core/services/network_monitor_service.dart';
import '../../core/services/navigation_tracker_service.dart';
import '../../core/services/notification_badge_service.dart';
import 'group_nav_screen.dart';
import 'group_screen.dart';
import 'login_screen.dart';
import 'account_devices_screen.dart';

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
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Écouter les changements des providers pour afficher les nouvelles notifications
    final groupProvider = context.read<GroupProvider>();
    groupProvider.addListener(_onGroupProviderChanged);
  }
  
  @override
  void dispose() {
    final groupProvider = context.read<GroupProvider>();
    groupProvider.removeListener(_onGroupProviderChanged);
    super.dispose();
  }
  
  void _onGroupProviderChanged() {
    if (mounted) {
      _checkPendingNotifications();
    }
  }
  
  /// Vérifie et affiche les notifications in-app en attente
  void _checkPendingNotifications() {
    if (!mounted) return;
    
    final groupProvider = context.read<GroupProvider>();
    final notifications = groupProvider.getPendingInAppNotifications();
    
    if (notifications.isEmpty) {
      return; // Pas de nouvelles notifications
    }
    
    debugPrint('🔔 [HomeScreen] ${notifications.length} notification(s) en attente à afficher');
    
    for (final notification in notifications) {
      if (!mounted) return;
      
      final type = notification['type'] as String;
      debugPrint('🔔 [HomeScreen] Affichage notification: $type');
      
      if (type == 'new_group') {
        final groupId = notification['groupId'] as String;
        final groupName = notification['groupName'] as String?;
        
        // CORRECTION: Ne plus afficher de notification texte pour les nouveaux groupes
        // Les badges suffisent pour indiquer qu'il y a un nouveau groupe
        debugPrint('🔔 [HomeScreen] Nouveau groupe détecté: $groupId - $groupName (badge uniquement, pas de notification texte)');
      }
    }
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final groupProvider = Provider.of<GroupProvider>(context, listen: false);
      final conversationProvider = Provider.of<ConversationProvider>(context, listen: false);
      
      // ✅ OPTIMISATION: Charger les groupes en premier et afficher immédiatement
      await groupProvider.fetchUserGroups();
      
      // ✅ OPTIMISATION: Afficher les groupes immédiatement après leur chargement
      if (mounted) {
        setState(() => _loading = false);
      }
      
      // ✅ OPTIMISATION: Charger les conversations en arrière-plan (non-bloquant)
      // Cela permet de recevoir les notifications même sans avoir ouvert de groupe
      conversationProvider.fetchConversations().then((_) {
        debugPrint('✅ [HomeScreen] Conversations chargées et abonnements WebSocket activés');
      }).catchError((e) {
        debugPrint('⚠️ [HomeScreen] Erreur chargement conversations (non-bloquant): $e');
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur chargement : $e')),
      );
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
            icon: const Icon(Icons.devices),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AccountDevicesScreen()),
            ),
            tooltip: 'Appareils du compte',
          ),
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
                : Consumer<NotificationBadgeService>(
                    builder: (context, badgeService, child) {
                      return ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: groups.length,
                        itemBuilder: (context, index) {
                          final GroupInfo g = groups[index];
                          final updatesCount = badgeService.getUpdatesCountForGroup(g.groupId);
                          final hasUpdates = updatesCount > 0;
                          
                          return ListTile(
                            leading: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                const Icon(Icons.group),
                                if (hasUpdates)
                                  Positioned(
                                    right: -4,
                                    top: -4,
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
                                        updatesCount > 99 ? '99+' : '$updatesCount',
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
                            title: Text(g.name),
                            onTap: () {
                              // CORRECTION: Ne pas nettoyer les badges quand on ouvre le groupe
                              // Les badges seront nettoyés seulement quand on ouvre une conversation spécifique
                              
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => GroupNavScreen(
                                    groupId: g.groupId,
                                    groupName: g.name,
                                  ),
                                ),
                              );
                            },
                          );
                        },
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
