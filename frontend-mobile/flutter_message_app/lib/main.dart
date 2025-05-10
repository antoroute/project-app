import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'core/providers/auth_provider.dart';
import 'core/providers/group_provider.dart';
import 'core/providers/conversation_provider.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/login_screen.dart';

Future<void> main() async {
  //On attend que Flutter soit prêt
  WidgetsFlutterBinding.ensureInitialized();

  //On crée le provider d'auth et on tente l'auto-login
  final authProvider = AuthProvider();
  await authProvider.tryAutoLogin();

  //On lance l'app en injectant le provider déjà initialisé
  runApp(
    MultiProvider(
      providers: <SingleChildWidget>[
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider(create: (_) => GroupProvider()),
        ChangeNotifierProvider(create: (_) => ConversationProvider()),
      ],
      child: SecureChatApp(isAuthenticated: authProvider.isAuthenticated),
    ),
  );
}

class SecureChatApp extends StatelessWidget {
  final bool isAuthenticated;

  const SecureChatApp({Key? key, required this.isAuthenticated})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Secure Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      //On choisit directement la page d’accueil ou la login
      home: isAuthenticated ? const HomeScreen() : const LoginScreen(),
    );
  }
}
