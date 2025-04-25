import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class GroupProvider extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  List<Map<String, dynamic>> _groups = [];

  List<Map<String, dynamic>> get groups => _groups;

  Future<void> fetchUserGroups() async {
    final token = await _storage.read(key: 'jwt');
    final resMe = await http.get(
      Uri.parse('https://auth.kavalek.fr/auth/me'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (resMe.statusCode == 200) {
      final data = jsonDecode(resMe.body);
      final groupIds = List<String>.from(data['user']['groups'] ?? []);

      final List<Map<String, dynamic>> loadedGroups = [];
      for (final id in groupIds) {
        final resGroup = await http.get(
          Uri.parse('https://api.kavalek.fr/api/groups/$id'),
          headers: {'Authorization': 'Bearer $token'},
        );

        if (resGroup.statusCode == 200) {
          final groupData = jsonDecode(resGroup.body);
          loadedGroups.add(groupData);
        }
      }

      _groups = loadedGroups;
      notifyListeners();
    } else {
      throw Exception('Failed to fetch user data: ${resMe.body}');
    }
  }
}