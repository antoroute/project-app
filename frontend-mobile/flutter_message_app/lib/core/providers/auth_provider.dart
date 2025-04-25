import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:jwt_decoder/jwt_decoder.dart';
import '../crypto/key_manager.dart';

class AuthProvider extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  String? _token;

  bool get isAuthenticated => _token != null;
  String? get token => _token;

  Future<void> login(String email, String password) async {
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
      await KeyManager().generateKeyPairForGroup("user_rsa");
      notifyListeners();
    } else {
      throw Exception('Failed to login');
    }
  }

  Future<void> register(String email, String password, String username) async {
    final url = Uri.parse('https://auth.kavalek.fr/auth/register');
    final res = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'password': password,
        'username': username
      }),
    );

    if (res.statusCode != 200) {
      throw Exception('Failed to register');
    }
  }

  Future<void> tryAutoLogin() async {
    final storedToken = await _storage.read(key: 'jwt');
    if (storedToken != null && !JwtDecoder.isExpired(storedToken)) {
      _token = storedToken;
      await KeyManager().generateKeyPairForGroup("user_rsa");
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _token = null;
    await _storage.delete(key: 'jwt');
    notifyListeners();
  }
}