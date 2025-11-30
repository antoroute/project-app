import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'core/providers/auth_provider.dart';
import 'core/providers/group_provider.dart';
import 'core/providers/conversation_provider.dart';
import 'core/services/websocket_service.dart';
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
    // 🚀 OPTIMISATION: Nettoyer l'Isolate crypto à la fermeture de l'app
    CryptoIsolateService.instance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached || state == AppLifecycleState.paused) {
      // Optionnel: Nettoyer l'Isolate quand l'app est en arrière-plan
      // CryptoIsolateService.instance.dispose();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
      if (auth.isAuthenticated && !_socketInitialized) {
        _socketInitialized = true;
        // Initialiser le service de présence global
        GlobalPresenceService().initialize();
        // Initialiser la connexion WebSocket une seule fois au niveau de l'app
        WebSocketService.instance.connect(context);
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
