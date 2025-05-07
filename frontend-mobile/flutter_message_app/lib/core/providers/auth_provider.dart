import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:flutter_message_app/core/crypto/key_manager.dart';
import 'package:pointycastle/pointycastle.dart' as pc;

class AuthProvider extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  String? _token;

  bool get isAuthenticated => _token != null;
  String? get token => _token;

  Future<void> login(String email, String password) async {
    try {
      final url = Uri.parse('https://auth.kavalek.fr/auth/login');
      final res = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        _token = data['token'];
        await _storage.write(key: 'jwt', value: _token);

        await KeyManager().generateUserKeyIfAbsent();

        notifyListeners();
      } else {
        throw Exception('Erreur login: ${res.body}');
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> tryAutoLogin() async {
    final storedToken = await _storage.read(key: 'jwt');
    if (storedToken != null && !JwtDecoder.isExpired(storedToken)) {
      _token = storedToken;
      await KeyManager().generateUserKeyIfAbsent();
      notifyListeners();
    }
  }

  Future<void> register(String email, String password, String username) async {
    try {
      await KeyManager().generateKeyPairForGroup('user_rsa');
      final keyPair = await KeyManager().getKeyPairForGroup('user_rsa');
      if (keyPair == null) throw Exception('Erreur génération clé RSA utilisateur');
      final publicKeyPem = encodePublicKeyToPem(keyPair.publicKey as pc.RSAPublicKey);

      final url = Uri.parse('https://auth.kavalek.fr/auth/register');
      final res = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
          'username': username,
          'publicKey': publicKeyPem,
        }),
      );

      if (res.statusCode != 200 && res.statusCode != 201) {
        throw Exception('Erreur d\'inscription : \'${res.body}\'');
      }
    } catch (e, stacktrace) {
      debugPrint('❌ Register failed: $e');
      debugPrintStack(stackTrace: stacktrace);
      rethrow;
    }
  }

  Future<void> logout() async {
    _token = null;
    await _storage.delete(key: 'jwt');
    notifyListeners();
  }
}
