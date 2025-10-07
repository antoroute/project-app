import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:jwt_decoder/jwt_decoder.dart';
// V2: RSA key management removed
import 'package:flutter_message_app/config/constants.dart';
import 'package:flutter_message_app/core/services/biometric_service.dart';
// pointycastle removed in v2

/// Fournit le JWT et gère la mise à jour via biométrie.
class AuthProvider extends ChangeNotifier {
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final BiometricService _biometric = BiometricService();
  String? _token;

  /// Retourne le JWT courant ou null si non connecté.
  String? get token => _token;

  /// Indique si l’utilisateur est authentifié.
  bool get isAuthenticated => _token != null;

  final Uri _loginUri    = Uri.parse('https://auth.kavalek.fr/auth/login');
  final Uri _refreshUri  = Uri.parse('https://auth.kavalek.fr/auth/refresh');
  final Uri _registerUri = Uri.parse('https://auth.kavalek.fr/auth/register');

  /// Retourne l'ID de l'utilisateur extrait du JWT (claim "id").
  String? get userId {
    if (_token == null) return null;
    try {
      final Map<String, dynamic> payload = JwtDecoder.decode(_token!);
      return (payload['sub'] as String?) ?? (payload['id'] as String?);
    } catch (_) {
      return null;
    }
  }

  /// Retourne le nom d'utilisateur extrait du JWT (claim "username").
  String? get username {
    if (_token == null) return null;
    try {
      final Map<String, dynamic> payload = JwtDecoder.decode(_token!);
      return payload['username'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Connexion : récupère accessToken et refreshToken, les stocke.
  Future<void> login(String email, String password) async {
    final http.Response response = await http.post(
      _loginUri,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'X-Client-Version': clientVersion,
      },
      body: jsonEncode(<String, String>{
        'email': email,
        'password': password,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Erreur login : ${response.body}');
    }

    final Map<String, dynamic> data = jsonDecode(response.body) as Map<String, dynamic>;
    final String? accessToken  = (data['accessToken'] as String?) ?? (data['access'] as String?);
    final String? refreshToken = (data['refreshToken'] as String?) ?? (data['refresh'] as String?);

    if (accessToken == null || refreshToken == null) {
      throw Exception('Réponse invalide du serveur lors du login');
    }

    await _storage.write(key: 'accessToken', value: accessToken);
    await _storage.write(key: 'refreshToken', value: refreshToken);
    _token = accessToken;
    
    notifyListeners();
  }

  /// Inscription v2: enregistre l'utilisateur via /auth/register
  Future<void> register(String email, String password, String username) async {
    final http.Response response = await http.post(
      _registerUri,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'X-Client-Version': clientVersion,
      },
      body: jsonEncode(<String, String>{
        'email': email,
        'password': password,
        'username': username,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Erreur d\'inscription : ${response.body}');
    }
  }

  /// Vérifie si un token valide est en mémoire et l’utilise pour l’auto-login.
  Future<void> tryAutoLogin() async {
    final String? stored = await _storage.read(key: 'accessToken');
    if (stored == null || JwtDecoder.isExpired(stored)) {
      return;
    }
    _token = stored;
    notifyListeners();
  }

  /// Rafraîchit le token via biométrie (popup) et l'API /refresh.
  Future<bool> refreshAccessToken() async {
    try {
      // Vérifier si la biométrie est disponible
      if (!await _biometric.canCheckBiometrics()) {
        debugPrint('🔐 [Auth] Biométrie non disponible');
        return false;
      }
      
      // Demander l'authentification biométrique
      debugPrint('🔐 [Auth] Demande d\'authentification biométrique...');
      final bool authenticated = await _biometric.authenticate();
      if (!authenticated) {
        debugPrint('🔐 [Auth] Authentification biométrique échouée');
        return false;
      }
      debugPrint('🔐 [Auth] Authentification biométrique réussie');
      
      // Récupérer le refresh token
      final String? storedRefresh = await _storage.read(key: 'refreshToken');
      if (storedRefresh == null) {
        debugPrint('🔐 [Auth] Aucun refresh token trouvé');
        return false;
      }
      debugPrint('🔐 [Auth] Refresh token trouvé, appel API...');
      
      // Appeler l'API de refresh
      final http.Response response = await http.post(
        _refreshUri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'X-Client-Version': clientVersion,
          'Authorization': 'Bearer $storedRefresh',
        },
        body: '{}', // CORRECTION: Ajouter un body JSON vide
      );
      
      debugPrint('🔐 [Auth] Réponse API refresh: ${response.statusCode}');
      
      if (response.statusCode != 200) {
        debugPrint('🔐 [Auth] Erreur API refresh: ${response.body}');
        // Si le refresh token est invalide, le supprimer
        if (response.statusCode == 401) {
          await _storage.delete(key: 'refreshToken');
          debugPrint('🔐 [Auth] Refresh token supprimé (401)');
        }
        return false;
      }
      
      final Map<String, dynamic> data = jsonDecode(response.body) as Map<String, dynamic>;
      final String? newAccessToken = (data['accessToken'] as String?) ?? (data['access'] as String?);
      
      if (newAccessToken == null) {
        debugPrint('🔐 [Auth] Aucun access token dans la réponse');
        return false;
      }
      
      // Mettre à jour le token en mémoire et en storage
      _token = newAccessToken;
      await _storage.write(key: 'accessToken', value: newAccessToken);
      notifyListeners();
      debugPrint('🔐 [Auth] Token rafraîchi avec succès');
      return true;
      
    } catch (e) {
      debugPrint('🔐 [Auth] Erreur lors du refresh: $e');
      // En cas d'erreur, nettoyer les tokens
      await _storage.delete(key: 'refreshToken');
      return false;
    }
  }

  /// Vérifie que le token en mémoire existe et n’est pas expiré, sinon tente un refresh.
  Future<bool> ensureTokenValid() async {
    if (_token == null) {
      final String? stored = await _storage.read(key: 'accessToken');
      if (stored == null) {
        return false;
      }
      _token = stored;
    }
    if (JwtDecoder.isExpired(_token!)) {
      return await refreshAccessToken();
    }
    return true;
  }

  /// Supprime le token et le refreshToken de la storage.
  Future<void> logout() async {
    _token = null;
    await _storage.delete(key: 'accessToken');
    await _storage.delete(key: 'refreshToken');
    notifyListeners();
  }

  /// Indique si la biométrie est disponible.
  Future<bool> canUseBiometrics() async {
    return await _biometric.canCheckBiometrics();
  }

  /// Vérifie la présence d’un refreshToken.
  Future<bool> hasRefreshToken() async {
    final String? token = await _storage.read(key: 'refreshToken');
    return token != null;
  }

  /// Connexion par biométrie : rafraîchit simplement l’accessToken.
  Future<bool> loginWithBiometrics() async {
    return await refreshAccessToken();
  }

  /// Expose les en-têtes à utiliser pour tous les appels REST (Content-Type + JWT).
  Future<Map<String, String>> getAuthHeaders() async {
    final bool valid = await ensureTokenValid();
    if (!valid) {
      final bool biometricsAvailable = await canUseBiometrics();
      if (!biometricsAvailable) {
        logout();
        throw Exception('Token invalide et biométrie indisponible - déconnexion');
      }
      // CORRECTION: Attendre le résultat de la reconnexion biométrique
      final bool biometricSuccess = await loginWithBiometrics();
      if (!biometricSuccess) {
        logout();
        throw Exception('Échec de la reconnexion biométrique - déconnexion');
      }
    }
    return <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_token',
      'X-Client-Version': clientVersion,
    };
  }
}