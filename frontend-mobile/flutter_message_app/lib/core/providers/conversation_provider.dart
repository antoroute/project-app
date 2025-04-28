import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

class ConversationProvider extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  List<Map<String, dynamic>> _conversations = [];

  List<Map<String, dynamic>> get conversations => _conversations;

  Future<void> fetchConversations(BuildContext context) async {
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final token = auth.token;
      if (token == null) throw Exception('Token JWT manquant');

      final res = await http.get(
        Uri.parse('https://api.kavalek.fr/api/conversations'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        _conversations = List<Map<String, dynamic>>.from(jsonDecode(res.body));
        notifyListeners();
      } else {
        throw Exception('Erreur récupération conversations: ${res.body}');
      }
    } catch (e) {
      debugPrint('❌ ConversationProvider error: $e');
      rethrow;
    }
  }

  List<Map<String, dynamic>> getConversationsForGroup(String groupId) {
    return _conversations.where((conv) => conv['groupId'] == groupId).toList();
  }
}
