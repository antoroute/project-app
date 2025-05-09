import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:flutter_message_app/core/crypto/key_manager.dart';
import 'package:flutter_message_app/core/services/biometric_service.dart';
import 'package:pointycastle/pointycastle.dart' as pc;

class AuthProvider extends ChangeNotifier {
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final BiometricService _biometric = BiometricService();
  String? _token;
  String? get token => _token;
  bool get isAuthenticated => _token != null;

  final Uri _loginUri    = Uri.parse('https://auth.kavalek.fr/auth/login');
  final Uri _refreshUri  = Uri.parse('https://auth.kavalek.fr/auth/refresh');
  final Uri _registerUri = Uri.parse('https://auth.kavalek.fr/auth/register');

  /// Connexion classique : récupère accessToken et refreshToken
  Future<void> login(String email, String password) async {
    final res = await http.post(
      _loginUri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw Exception('Erreur login: ${res.body}');
    }
    final data = jsonDecode(res.body);
    final accessToken  = data['accessToken']  as String?;
    final refreshToken = data['refreshToken'] as String?;
    if (accessToken == null || refreshToken == null) {
      throw Exception('Réponse invalide du serveur');
    }
    await _storage.write(key: 'accessToken', value: accessToken);
    await _storage.write(key: 'refreshToken', value: refreshToken);
    _token = accessToken;
    await KeyManager().generateUserKeyIfAbsent();
    notifyListeners();
  }

  /// Inscription : envoie email, password, username et publicKey
  Future<void> register(String email, String password, String username) async {
    await KeyManager().generateKeyPairForGroup('user_rsa');
    final keyPair = await KeyManager().getKeyPairForGroup('user_rsa');
    if (keyPair == null) throw Exception('Erreur génération clé RSA utilisateur');
    final publicKeyPem = encodePublicKeyToPem(keyPair.publicKey as pc.RSAPublicKey);

    final res = await http.post(
      _registerUri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'password': password,
        'username': username,
        'publicKey': publicKeyPem,
      }),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('Erreur d\'inscription: ${res.body}');
    }
  }

  /// Essaie auto-login : accès direct ou via refresh si expiré
  Future<void> tryAutoLogin() async {
    final stored = await _storage.read(key: 'accessToken');
    if (stored != null) {
      if (!JwtDecoder.isExpired(stored)) {
        _token = stored;
      } else {
        final ok = await refreshAccessToken();
        if (!ok) return;
      }
      await KeyManager().generateUserKeyIfAbsent();
      notifyListeners();
    }
  }

  /// Rafraîchissement du token via biométrie et appel /refresh
  Future<bool> refreshAccessToken() async {
    try {
      if (!await _biometric.canCheckBiometrics()) return false;
      final authenticated = await _biometric.authenticate();
      if (!authenticated) return false;
      final refresh = await _storage.read(key: 'refreshToken');
      if (refresh == null) return false;
      final res = await http.post(
        _refreshUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refreshToken': refresh}),
      );
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body);
      final newToken = data['accessToken'] as String?;
      if (newToken == null) return false;
      _token = newToken;
      await _storage.write(key: 'accessToken', value: newToken);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Si le JWT en mémoire est absent ou expiré,
  /// tente un refresh via biométrie avant de continuer.
  Future<bool> ensureTokenValid() async {
    if (_token == null) {
      final stored = await _storage.read(key: 'accessToken');
      if (stored == null) return false;
      _token = stored;
    }

    if (JwtDecoder.isExpired(_token!)) {
      return await refreshAccessToken(); 
      // refreshAccessToken() affiche la popup biométrique
    }

    return true;
  }

  /// Supprime tous les tokens
  Future<void> logout() async {
    _token = null;
    await _storage.delete(key: 'accessToken');
    await _storage.delete(key: 'refreshToken');
    notifyListeners();
  }

  /// Indique si la biométrie est disponible
  Future<bool> canUseBiometrics() async {
    return await _biometric.canCheckBiometrics();
  }

  /// Vérifie la présence d'un refreshToken en storage
  Future<bool> hasRefreshToken() async {
    final token = await _storage.read(key: 'refreshToken');
    return token != null;
  }

  /// Connexion via biométrie : rafraîchit le token
  Future<bool> loginWithBiometrics() async {
    return await refreshAccessToken();
  }

  Future<Map<String, String>> getAuthHeaders() async {
    final ok = await ensureTokenValid();
    if (!ok) throw Exception('Session expirée');
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_token',
    };
  }
}
