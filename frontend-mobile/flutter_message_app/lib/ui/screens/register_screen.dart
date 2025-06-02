import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/services/snackbar_service.dart';
import 'home_screen.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({Key? key}) : super(key: key);

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final TextEditingController _usernameController        = TextEditingController();
  final TextEditingController _emailController           = TextEditingController();
  final TextEditingController _passwordController        = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final GlobalKey<FormState> _formKey                    = GlobalKey<FormState>();
  bool _isLoading = false;

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Entrez un mot de passe';
    }
    if (value.length < 6) {
      return 'Au moins 6 caractères';
    }
    if (!RegExp(r'[A-Z]').hasMatch(value)) {
      return 'Au moins une majuscule';
    }
    if (!RegExp(r'[0-9!@#\$%^&*(),.?":{}|<>]').hasMatch(value)) {
      return 'Au moins un chiffre ou caractère spécial';
    }
    return null;
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    try {
      final authProvider =
          Provider.of<AuthProvider>(context, listen: false);
      // Inscription
      await authProvider.register(
        _emailController.text.trim(),
        _passwordController.text.trim(),
        _usernameController.text.trim(),
      );
      // Auto-login
      await authProvider.login(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
      SnackbarService.showSuccess(
        context,
        'Compte créé et connecté avec succès',
      );
    } catch (e) {
      SnackbarService.showError(
        context,
        'Erreur d\'inscription : $e',
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
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
            children: <Widget>[
              TextFormField(
                controller: _usernameController,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration:
                    const InputDecoration(labelText: 'Nom d\'utilisateur'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Entrez un nom d\'utilisateur';
                  }
                  if (value.length < 3) {
                    return 'Au moins 3 caractères';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emailController,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Entrez votre email';
                  }
                  if (!value.contains('@')) {
                    return 'Email invalide';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passwordController,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration:
                    const InputDecoration(labelText: 'Mot de passe'),
                obscureText: true,
                validator: _validatePassword,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirmPasswordController,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration:
                    const InputDecoration(labelText: 'Confirmer le mot de passe'),
                obscureText: true,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Confirmez le mot de passe';
                  }
                  if (value != _passwordController.text) {
                    return 'Les mots de passe ne correspondent pas';
                  }
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
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const LoginScreen()),
                  );
                },
                child: const Text('Déjà inscrit ? Se connecter'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
