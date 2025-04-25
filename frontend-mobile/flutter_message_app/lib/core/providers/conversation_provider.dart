import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ConversationProvider extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  List<Map<String, dynamic>> _conversations = [];

  List<Map<String, dynamic>> get conversations => _conversations;

  Future<void> fetchConversations() async {
    final token = await _storage.read(key: 'jwt');
    final res = await http.get(
      Uri.parse('https://api.kavalek.fr/api/conversations'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (res.statusCode == 200) {
      _conversations = List<Map<String, dynamic>>.from(jsonDecode(res.body));
      notifyListeners();
    } else {
      throw Exception('Failed to load conversations: ${res.body}');
    }
  }

  List<Map<String, dynamic>> getConversationsForGroup(String groupId) {
    return _conversations
        .where((conv) => conv['groupId'] == groupId)
        .toList();
  }
}