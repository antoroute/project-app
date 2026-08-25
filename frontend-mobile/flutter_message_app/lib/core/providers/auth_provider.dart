import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:jwt_decoder/jwt_decoder.dart';
// V2: RSA key management removed
import 'package:flutter_message_app/config/constants.dart';
import 'package:flutter_message_app/core/services/biometric_service.dart';
import 'package:flutter_message_app/core/services/message_key_cache.dart';
import 'package:flutter_message_app/core/services/persistent_message_key_cache.dart';
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'package:flutter_message_app/core/services/account_device_trust_service.dart';
import 'package:flutter_message_app/core/models/account_device.dart';
import 'package:flutter_message_app/core/crypto/account_device_identity_service.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';

// pointycastle removed in v2

/// Fournit le JWT et gère la mise à jour via biométrie.
class AuthProvider extends ChangeNotifier {
  AuthProvider({DeviceTrustTransport? deviceTrustTransport}) {
    _deviceTrustService = AccountDeviceTrustService(
      transport:
          deviceTrustTransport ??
          HttpDeviceTrustTransport(headers: getAuthHeaders),
    );
  }

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final BiometricService _biometric = BiometricService();
  late final AccountDeviceTrustService _deviceTrustService;
  String? _token;
  DeviceTrustState _deviceTrustState = DeviceTrustState.unauthenticated;
  AccountDevice? _currentAccountDevice;
  String? _deviceTrustError;

  /// Retourne le JWT courant ou null si non connecté.
  String? get token => _token;

  /// Indique si l’utilisateur est authentifié.
  bool get isAuthenticated => _token != null;

  DeviceTrustState get deviceTrustState => _deviceTrustState;
  AccountDevice? get currentAccountDevice => _currentAccountDevice;
  String? get currentDeviceId => _currentAccountDevice?.deviceId;
  String? get deviceTrustError => _deviceTrustError;
  bool get canUseMessaging =>
      isAuthenticated && _deviceTrustState == DeviceTrustState.active;

  final Uri _loginUri = Uri.parse('https://auth.kavalek.fr/auth/login');
  final Uri _refreshUri = Uri.parse('https://auth.kavalek.fr/auth/refresh');
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

  String? _subjectOf(String token) {
    try {
      final payload = JwtDecoder.decode(token);
      return (payload['sub'] as String?) ?? (payload['id'] as String?);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearDeviceSecurityState() async {
    await SessionDeviceService.instance.clearMemoryCache();
    await AccountDeviceIdentityService.instance.clearMemoryCache();
    await KeyManagerFinal.instance.clearMemoryCaches();
    MessageKeyCache.instance.clear();
    await PersistentMessageKeyCache.instance.clear();
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
    final previousUserId = userId;
    final http.Response response = await http.post(
      _loginUri,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'X-Client-Version': clientVersion,
        'X-App-Secret': appSecret,
      },
      body: jsonEncode(<String, String>{'email': email, 'password': password}),
    );

    if (response.statusCode != 200) {
      throw Exception('Erreur login : ${response.body}');
    }

    final Map<String, dynamic> data =
        jsonDecode(response.body) as Map<String, dynamic>;
    final String? accessToken =
        (data['accessToken'] as String?) ?? (data['access'] as String?);
    final String? refreshToken =
        (data['refreshToken'] as String?) ?? (data['refresh'] as String?);

    if (accessToken == null || refreshToken == null) {
      throw Exception('Réponse invalide du serveur lors du login');
    }

    final nextUserId = _subjectOf(accessToken);
    if (nextUserId == null) {
      throw Exception('Access token sans identité utilisateur valide');
    }
    if (previousUserId != null && previousUserId != nextUserId) {
      await _clearDeviceSecurityState();
    }

    await _storage.write(key: 'accessToken', value: accessToken);
    await _storage.write(key: 'refreshToken', value: refreshToken);
    _token = accessToken;
    await _resolveDeviceTrust(explicitEnrollment: true, password: password);
  }

  /// Inscription v2: enregistre l'utilisateur via /auth/register
  Future<void> register(String email, String password, String username) async {
    final http.Response response = await http.post(
      _registerUri,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'X-Client-Version': clientVersion,
        'X-App-Secret': appSecret,
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
    await _resolveDeviceTrust(explicitEnrollment: false);
  }

  Future<void> _resolveDeviceTrust({
    required bool explicitEnrollment,
    String? password,
    bool announceChecking = true,
  }) async {
    final accountId = userId;
    if (accountId == null) {
      _deviceTrustState = DeviceTrustState.error;
      _deviceTrustError = 'invalid_authenticated_account';
      notifyListeners();
      return;
    }
    if (announceChecking) {
      _deviceTrustState = DeviceTrustState.checking;
    }
    _deviceTrustError = null;
    if (announceChecking) notifyListeners();
    try {
      final result = await _deviceTrustService.enrollOrRefresh(
        accountId: accountId,
        explicitEnrollment: explicitEnrollment,
        password: password,
      );
      _deviceTrustState = result.state;
      _currentAccountDevice = result.device;
    } on DeviceTrustException catch (error) {
      _deviceTrustState = DeviceTrustState.error;
      _deviceTrustError = error.code;
      _currentAccountDevice = null;
    } on AccountDeviceIdentityException catch (error) {
      _deviceTrustState = DeviceTrustState.error;
      _deviceTrustError = error.code;
      _currentAccountDevice = null;
    } catch (_) {
      _deviceTrustState = DeviceTrustState.error;
      _deviceTrustError = 'device_trust_unavailable';
      _currentAccountDevice = null;
    }
    notifyListeners();
  }

  Future<void> refreshDeviceTrust({bool showChecking = true}) async {
    await _resolveDeviceTrust(
      explicitEnrollment: false,
      announceChecking: showChecking,
    );
  }

  Future<void> enrollCurrentDevice(String password) async {
    await _resolveDeviceTrust(explicitEnrollment: true, password: password);
  }

  Future<List<AccountDevice>> fetchAccountDevices() async {
    if (!canUseMessaging) {
      throw const DeviceTrustException('active_device_required');
    }
    return _deviceTrustService.fetchDevices();
  }

  Future<void> decidePendingDevice({
    required AccountDevice target,
    required DeviceApprovalDecision decision,
  }) async {
    final accountId = userId;
    final approverDeviceId = currentDeviceId;
    if (!canUseMessaging || accountId == null || approverDeviceId == null) {
      throw const DeviceTrustException('active_device_required');
    }
    final result = await _deviceTrustService.decide(
      accountId: accountId,
      approverDeviceId: approverDeviceId,
      target: target,
      decision: decision,
    );
    _deviceTrustState = result.state;
    _currentAccountDevice = result.device;
    _deviceTrustError = null;
    notifyListeners();
  }

  /// Rafraîchit le token via biométrie (popup) et l'API /refresh.
  Future<bool> refreshAccessToken() async {
    try {
      final previousUserId = userId;
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
          'X-App-Secret': appSecret,
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

      final Map<String, dynamic> data =
          jsonDecode(response.body) as Map<String, dynamic>;
      final String? newAccessToken =
          (data['accessToken'] as String?) ?? (data['access'] as String?);

      if (newAccessToken == null) {
        debugPrint('🔐 [Auth] Aucun access token dans la réponse');
        return false;
      }

      final nextUserId = _subjectOf(newAccessToken);
      if (nextUserId == null ||
          (previousUserId != null && previousUserId != nextUserId)) {
        debugPrint('🔐 [Auth] Sujet inattendu dans le nouvel access token');
        await logout();
        return false;
      }

      // Mettre à jour le token en mémoire et en storage
      _token = newAccessToken;
      await _storage.write(key: 'accessToken', value: newAccessToken);
      if (_deviceTrustState != DeviceTrustState.active) {
        await _resolveDeviceTrust(explicitEnrollment: false);
      } else {
        notifyListeners();
      }
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
    _deviceTrustState = DeviceTrustState.unauthenticated;
    _currentAccountDevice = null;
    _deviceTrustError = null;
    await _storage.delete(key: 'accessToken');
    await _storage.delete(key: 'refreshToken');
    await _clearDeviceSecurityState();
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
        await logout();
        throw Exception(
          'Token invalide et biométrie indisponible - déconnexion',
        );
      }
      // CORRECTION: Attendre le résultat de la reconnexion biométrique
      final bool biometricSuccess = await loginWithBiometrics();
      if (!biometricSuccess) {
        await logout();
        throw Exception('Échec de la reconnexion biométrique - déconnexion');
      }
    }
    return <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_token',
      'X-Client-Version': clientVersion,
      'X-App-Secret': appSecret,
    };
  }
}
