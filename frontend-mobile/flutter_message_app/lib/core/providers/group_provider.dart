import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'auth_provider.dart';

class GroupProvider extends ChangeNotifier {
  List<Map<String, dynamic>> _groups = [];

  List<Map<String, dynamic>> get groups => _groups;

  Future<void> fetchUserGroups(BuildContext context) async {
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final token = auth.token;
      if (token == null) throw Exception('Token JWT manquant');

      final resMe = await http.get(
        Uri.parse('https://auth.kavalek.fr/auth/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (resMe.statusCode != 200) {
        throw Exception('Erreur récupération utilisateur: ${resMe.body}');
      }

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
        } else {
          debugPrint('⚠️ Impossible de récupérer le groupe $id: ${resGroup.body}');
        }
      }

      _groups = loadedGroups;
      notifyListeners();
    } catch (e) {
      debugPrint('❌ GroupProvider error: $e');
      rethrow;
    }
  }
}
