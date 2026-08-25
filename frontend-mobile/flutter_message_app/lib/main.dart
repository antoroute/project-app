import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'core/providers/auth_provider.dart';
import 'core/providers/group_provider.dart';
import 'core/providers/conversation_provider.dart';
import 'core/services/websocket_service.dart';
import 'core/services/websocket_heartbeat_service.dart';
import 'core/services/network_monitor_service.dart';
import 'core/services/message_queue_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/global_presence_service.dart';
import 'core/services/notification_badge_service.dart';
import 'core/services/persistent_message_key_cache.dart';
import 'core/crypto/key_manager_final.dart';
import 'core/crypto/crypto_isolate_service.dart';
import 'ui/screens/device_trust_gate_screen.dart';
import 'ui/screens/login_screen.dart';
import 'ui/themes/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🔐 Charger les variables d'environnement depuis .env
  await dotenv.load(fileName: ".env");

  // 🔒 Forcer l'orientation portrait uniquement
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

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
        ChangeNotifierProvider<NotificationBadgeService>.value(
          value: NotificationBadgeService(),
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
    
    // Arrêter le nettoyage périodique
    PersistentMessageKeyCache.instance.stopPeriodicCleanup();
    
    // 🚀 OPTIMISATION: Nettoyer l'Isolate crypto à la fermeture de l'app
    CryptoIsolateService.instance.dispose();
    
    // Restaurer les orientations par défaut à la fermeture
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    
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
          if (auth.canUseMessaging) {
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
      if (auth.canUseMessaging && !_socketInitialized) {
        _socketInitialized = true;
        
        // Initialiser les services
        _initializeServices(context);
        
        // Nettoyer les caches expirés au démarrage
        _cleanupExpiredCaches(context);
        
        // Démarrer le nettoyage périodique
        PersistentMessageKeyCache.instance.startPeriodicCleanup();
      } else if (!auth.canUseMessaging && _socketInitialized) {
        _socketInitialized = false;
        WebSocketHeartbeatService().stop();
        WebSocketService.instance.disconnect();
        PersistentMessageKeyCache.instance.stopPeriodicCleanup();
      }
  }
  
  /// Nettoie les caches expirés au démarrage
  Future<void> _cleanupExpiredCaches(BuildContext context) async {
    try {
      // Nettoyer message keys
      await PersistentMessageKeyCache.instance.cleanupExpiredKeys();
      
      // Nettoyer group keys (via ConversationProvider si disponible)
      try {
        final conversationProvider = context.read<ConversationProvider>();
        await conversationProvider.keyDirectory.cleanupExpiredKeys();
      } catch (e) {
        debugPrint('⚠️ Erreur nettoyage group keys: $e');
      }
      
      debugPrint('✅ Nettoyage caches expirés terminé');
    } catch (e) {
      debugPrint('⚠️ Erreur nettoyage caches: $e');
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
          home: auth.isAuthenticated
              ? const DeviceTrustGateScreen()
              : const LoginScreen(),
        );
      },
    );
  }
}
