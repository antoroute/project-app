import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/snackbar_service.dart';
import '../../core/crypto/key_manager.dart';
import 'login_screen.dart';
import 'home_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _usernameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Entrez un mot de passe';
    if (value.length < 6) return 'Au moins 6 caractères';
    if (!RegExp(r'[A-Z]').hasMatch(value)) return 'Au moins une majuscule';
    if (!RegExp(r'[0-9!@#\$%^&*(),.?":{}|<>]').hasMatch(value)) return 'Au moins un chiffre ou un caractère spécial';
    return null;
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      try {
        await authProvider.register(
          _emailController.text.trim(),
          _passwordController.text.trim(),
          _usernameController.text.trim(),
        );
      } catch (e) {
        // Si le message d'erreur contient 'User registered', on continue comme un succès
        if (e.toString().contains('User registered')) {
          debugPrint('🟢 Utilisateur créé malgré exception');
        } else {
          rethrow;
        }
      }

      // 🎯 Auto-login après inscription
      await authProvider.login(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );

      // 🎯 Naviguer vers la page d'accueil
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
        SnackbarService.showSuccess(context, 'Compte créé et connecté avec succès.');
      }
    } catch (e, stacktrace) {
      debugPrint('❌ Register error: $e');
      debugPrintStack(stackTrace: stacktrace);
      SnackbarService.showError(context, 'Erreur d\'inscription : $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Créer un compte')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: 'Nom d\'utilisateur'),
                validator: (value) => value == null || value.isEmpty ? 'Entrez un nom d\'utilisateur' : null,
              ),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.isEmpty) return 'Entrez votre email';
                  if (!value.contains('@')) return 'Email invalide';
                  return null;
                },
              ),
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Mot de passe'),
                obscureText: true,
                validator: _validatePassword,
              ),
              TextFormField(
                controller: _confirmPasswordController,
                decoration: const InputDecoration(labelText: 'Confirmer le mot de passe'),
                obscureText: true,
                validator: (value) {
                  if (value == null || value.isEmpty) return 'Confirmez le mot de passe';
                  if (value != _passwordController.text) return 'Les mots de passe ne correspondent pas';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              _isLoading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: _register,
                      child: const Text('Créer un compte'),
                    ),
              TextButton(
                onPressed: () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                ),
                child: const Text('Déjà inscrit ? Se connecter'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
