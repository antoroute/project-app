import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'core/providers/auth_provider.dart';
import 'core/providers/group_provider.dart';
import 'core/providers/conversation_provider.dart';
import 'core/services/websocket_service.dart';
import 'core/services/websocket_heartbeat_service.dart';
import 'core/services/network_monitor_service.dart';
import 'core/services/message_queue_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/global_presence_service.dart';
import 'core/crypto/key_manager_final.dart';
import 'core/crypto/crypto_isolate_service.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/login_screen.dart';
import 'ui/themes/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🚀 Initialiser cryptography_flutter pour les performances natives
  KeyManagerFinal.initialize();
  
  // 🔔 Initialiser le service de notifications
  await NotificationService.initialize();

  await initializeDateFormatting('fr_FR', null);

  final authProvider = AuthProvider();
  await authProvider.tryAutoLogin();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider<GroupProvider>(
          create: (context) => GroupProvider(context.read<AuthProvider>()),
        ),
        ChangeNotifierProvider<ConversationProvider>(
          create: (context) => ConversationProvider(context.read<AuthProvider>()),
        ),
      ],
      child: const SecureChatApp(),
    ),
  );
}

class SecureChatApp extends StatefulWidget {
  const SecureChatApp({Key? key}) : super(key: key);

  @override
  State<SecureChatApp> createState() => _SecureChatAppState();
}

class _SecureChatAppState extends State<SecureChatApp> with WidgetsBindingObserver {
  bool _socketInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    
    // Nettoyer les services
    WebSocketHeartbeatService().stop();
    NetworkMonitorService().dispose();
    MessageQueueService().dispose();
    
    // 🚀 OPTIMISATION: Nettoyer l'Isolate crypto à la fermeture de l'app
    CryptoIsolateService.instance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ws = WebSocketService.instance;
    
    switch (state) {
      case AppLifecycleState.resumed:
        // App revient au premier plan : reconnecter le WebSocket si nécessaire
        // Repasser en mode normal (heartbeat plus fréquent)
        debugPrint('▶️ [AppLifecycle] App resumed, switching to normal mode');
        WebSocketHeartbeatService().setBackgroundMode(false);
        
        if (context.mounted) {
          final auth = context.read<AuthProvider>();
          if (auth.isAuthenticated) {
            // Vérifier la connectivité de manière asynchrone
            NetworkMonitorService().hasInternetConnection().then((hasNetwork) {
              if (hasNetwork) {
                if (ws.status != SocketStatus.connected) {
                  debugPrint('🔄 [AppLifecycle] App resumed, reconnecting WebSocket...');
                  ws.connect(context).then((_) {
                    WebSocketHeartbeatService().start();
                  });
                } else {
                  // Si déjà connecté, redémarrer le heartbeat en mode normal
                  WebSocketHeartbeatService().start();
                }
              } else {
                debugPrint('⚠️ [AppLifecycle] Pas de connexion réseau disponible');
              }
            });
          }
        }
        break;
        
      case AppLifecycleState.paused:
        // App passe en arrière-plan : garder la connexion ouverte pour recevoir les notifications
        // Mais passer en mode économie d'énergie (heartbeat moins fréquent)
        debugPrint('⏸️ [AppLifecycle] App paused, switching to power-saving mode');
        WebSocketHeartbeatService().setBackgroundMode(true);
        break;
        
      case AppLifecycleState.inactive:
        // App est inactive (ex: notification drawer ouvert)
        // Garder la connexion ouverte
        break;
        
      case AppLifecycleState.detached:
        // App est sur le point d'être fermée
        debugPrint('🔌 [AppLifecycle] App detached, disconnecting WebSocket');
        WebSocketHeartbeatService().stop();
        ws.disconnect();
        break;
        
      case AppLifecycleState.hidden:
        // App est cachée (Android)
        break;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
      if (auth.isAuthenticated && !_socketInitialized) {
        _socketInitialized = true;
        
        // Initialiser les services
        _initializeServices(context);
      }
  }
  
  Future<void> _initializeServices(BuildContext context) async {
    // Initialiser le service de surveillance réseau
    await NetworkMonitorService().initialize();
    
    // Initialiser la queue de messages
    await MessageQueueService().initialize();
    
        // Initialiser le service de présence global
        GlobalPresenceService().initialize();
    
    // Vérifier la connectivité avant de connecter le WebSocket
    final hasNetwork = await NetworkMonitorService().hasInternetConnection();
    if (hasNetwork) {
        // Initialiser la connexion WebSocket une seule fois au niveau de l'app
      WebSocketService.instance.connect(context).then((_) {
        // Démarrer le heartbeat une fois connecté
        WebSocketHeartbeatService().start();
      });
    } else {
      debugPrint('⚠️ [App] Pas de connexion réseau, WebSocket non connecté');
      }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        return MaterialApp(
          title: 'Secure Chat',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.theme,
          home: auth.isAuthenticated ? const HomeScreen() : const LoginScreen(),
        );
      },
    );
  }
}
