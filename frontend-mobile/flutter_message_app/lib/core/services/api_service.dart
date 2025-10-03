import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/models/conversation.dart';
import 'package:flutter_message_app/core/models/message.dart';
import 'package:flutter_message_app/core/models/message_v2.dart';
import 'package:flutter_message_app/core/models/group_info.dart';
import 'package:flutter_message_app/config/constants.dart';

/// Exception levée en cas de rate limit (429).
class RateLimitException implements Exception {
  final String message;
  RateLimitException([this.message = 'Trop de requêtes, veuillez réessayer plus tard.']);
  @override
  String toString() => 'RateLimitException: $message';
}

/// Service centralisé pour tous les appels HTTP vers l’API.
class ApiService {
  final AuthProvider _authProvider;
  static const String _baseUrl = messagingBase;

  ApiService(this._authProvider);

  /// En-têtes communs incluant JWT.
  Future<Map<String, String>> _buildHeaders() async {
    return await _authProvider.getAuthHeaders();
  }

  /// Crée un nouveau groupe via POST /groups.
  Future<String> createGroup({
    required String name,
    required String groupSigningPubKeyB64,
    required String groupKEMPubKeyB64,
  }) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/groups');
    final String payload = jsonEncode(<String, String>{
      'name': name,
      'groupSigningPubKey': groupSigningPubKeyB64,
      'groupKEMPubKey': groupKEMPubKeyB64,
    });
    final http.Response response = await http.post(uri, headers: headers, body: payload);

    if (response.statusCode == 201 || response.statusCode == 200) {
      return (jsonDecode(response.body) as Map<String, dynamic>)['groupId'] as String;
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de la création du groupe.');
  }

  /// Récupère la liste des groupes de l’utilisateur via GET /groups.
  Future<List<GroupInfo>> fetchUserGroups() async {
    final headers = await _buildHeaders();
    final uri = Uri.parse('$_baseUrl/groups');
    final res = await http.get(uri, headers: headers);

    if (res.statusCode == 200) {
      final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
      return body.map((dynamic e) {
        return GroupInfo.fromJson(e as Map<String, dynamic>);
      }).toList();
    }
    if (res.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${res.statusCode} lors de la récupération des groupes.');
  }


  /// Récupère les détails d’un groupe via GET /groups/:id.
  Future<Map<String, dynamic>> fetchGroupDetail(String groupId) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/groups/$groupId');
    final http.Response response = await http.get(uri, headers: headers);

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de la récupération des détails du groupe.');
  }

  /// Envoie une demande de jointure via POST /groups/:id/join-requests.
  Future<String> sendJoinRequest({
    required String groupId,
    required String groupSigningPubKeyB64,
    required String groupKEMPubKeyB64,
  }) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/groups/$groupId/join-requests');
    final String payload = jsonEncode(<String, String>{
      'groupSigningPubKey': groupSigningPubKeyB64,
      'groupKEMPubKey': groupKEMPubKeyB64,
    });
    final http.Response response = await http.post(uri, headers: headers, body: payload);

    if (response.statusCode == 201 || response.statusCode == 200) {
      final Map<String, dynamic> body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['requestId'] as String;
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de la demande de jointure.');
  }

  /// Récupère les demandes de jointure via GET /groups/:id/join-requests.
  Future<List<Map<String, dynamic>>> fetchJoinRequests(String groupId) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/groups/$groupId/join-requests');
    final http.Response response = await http.get(uri, headers: headers);

    if (response.statusCode == 200) {
      final List<dynamic> body = jsonDecode(response.body) as List<dynamic>;
      return body.cast<Map<String, dynamic>>();
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de la récupération des demandes de jointure.');
  }

  /// Vote sur une demande de jointure via POST /groups/:id/join-requests/:reqId/vote.
  Future<Map<String, int>> voteJoinRequest({
    required String groupId,
    required String requestId,
    required bool vote,
  }) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/groups/$groupId/join-requests/$requestId/vote');
    final String payload = jsonEncode(<String, bool>{ 'vote': vote });
    final http.Response response = await http.post(uri, headers: headers, body: payload);

    if (response.statusCode == 200) {
      final Map<String, dynamic> body = jsonDecode(response.body) as Map<String, dynamic>;
      return <String, int>{
        'yesVotes': body['yesVotes'] as int,
        'noVotes': body['noVotes'] as int,
      };
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors du vote de la demande de jointure.');
  }

  /// Accepte ou rejette une demande de jointure via POST /groups/:id/join-requests/:reqId/handle.
  Future<void> handleJoinRequest({
    required String groupId,
    required String requestId,
    required String action, // "accept" ou "reject"
  }) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/groups/$groupId/join-requests/$requestId/handle');
    final String payload = jsonEncode(<String, String>{ 'action': action });
    final http.Response response = await http.post(uri, headers: headers, body: payload);

    if (response.statusCode == 200) {
      return;
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors du traitement de la demande de jointure.');
  }

  /// Récupère les membres d’un groupe via GET /groups/:id/members.
  Future<List<Map<String, dynamic>>> fetchGroupMembers(String groupId) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/groups/$groupId/members');
    final http.Response response = await http.get(uri, headers: headers);

    if (response.statusCode == 200) {
      final List<dynamic> body = jsonDecode(response.body) as List<dynamic>;
      return body.cast<Map<String, dynamic>>();
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de la récupération des membres du groupe.');
  }

  // ─── V2: Group Device Keys ────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchGroupDeviceKeys(String groupId) async {
    final headers = await _buildHeaders();
    final uri = Uri.parse('$_baseUrl/keys/group/$groupId');
    final res = await http.get(uri, headers: headers);
    if (res.statusCode == 200) {
      final List<dynamic> body = jsonDecode(res.body) as List<dynamic>;
      return body.cast<Map<String, dynamic>>();
    }
    if (res.statusCode == 429) throw RateLimitException();
    throw Exception('Erreur ${res.statusCode} lors du fetch des clés devices.');
  }

  Future<void> publishGroupDeviceKey({
    required String groupId,
    required String deviceId,
    required String pkSigB64,
    required String pkKemB64,
    int keyVersion = 1,
  }) async {
    final headers = await _buildHeaders();
    final uri = Uri.parse('$_baseUrl/keys/group/$groupId/devices');
    final payload = jsonEncode({
      'deviceId': deviceId,
      'pk_sig': pkSigB64,
      'pk_kem': pkKemB64,
      'key_version': keyVersion,
    });
    final res = await http.post(uri, headers: headers, body: payload);
    if (res.statusCode == 201) return;
    if (res.statusCode == 429) throw RateLimitException();
    throw Exception('Erreur ${res.statusCode} lors de la publication clé device.');
  }

  Future<void> revokeGroupDevice({
    required String groupId,
    required String deviceId,
  }) async {
    final headers = await _buildHeaders();
    final uri = Uri.parse('$_baseUrl/keys/group/$groupId/devices/$deviceId');
    final res = await http.delete(uri, headers: headers);
    if (res.statusCode == 200) return;
    if (res.statusCode == 429) throw RateLimitException();
    throw Exception('Erreur ${res.statusCode} lors de la révocation device.');
  }

  /// Crée une nouvelle conversation via POST /conversations.
  Future<String> createConversation({
    required String groupId,
    required List<String> userIds,
    required Map<String, String> encryptedSecrets,
    required String creatorSignature,
  }) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/conversations');
    final String payload = jsonEncode(<String, dynamic>{
      'groupId': groupId,
      'userIds': userIds,
      'encryptedSecrets': encryptedSecrets,
      'creatorSignature': creatorSignature,
    });
    final http.Response response = await http.post(uri, headers: headers, body: payload);

    if (response.statusCode == 201) {
      return (jsonDecode(response.body) as Map<String, dynamic>)['conversationId'] as String;
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de la création de la conversation.');
  }

  /// Récupère la liste des conversations de l’utilisateur via GET /conversations.
  Future<List<Conversation>> fetchConversations() async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/conversations');
    final http.Response response = await http.get(uri, headers: headers);

    if (response.statusCode == 200) {
      final List<dynamic> body = jsonDecode(response.body) as List<dynamic>;
      debugPrint('📥 fetchConversations raw JSON: $body');
      return body
          .map((dynamic e) => Conversation.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de la récupération des conversations.');
  }

  /// Récupère les détails d’une conversation via GET /conversations/:id.
  Future<Conversation> fetchConversationDetail(String conversationId) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/conversations/$conversationId');
    final http.Response response = await http.get(uri, headers: headers);

    if (response.statusCode == 200) {
      final bodyText = response.body;
      debugPrint('📥 fetchConversationDetail raw JSON: $bodyText');
      final Map<String, dynamic> body = jsonDecode(bodyText) as Map<String, dynamic>;
      return Conversation.fromJson(body);
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de la récupération des détails de la conversation.');
  }

  /// Récupère l’historique des messages pour une conversation via GET /conversations/:id/messages.
  Future<List<Message>> fetchMessages(String conversationId) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/conversations/$conversationId/messages');
    final http.Response response = await http.get(uri, headers: headers);

    if (response.statusCode == 200) {
      final List<dynamic> body = jsonDecode(response.body) as List<dynamic>;
      return body.map((dynamic e) => Message.fromJson(e as Map<String, dynamic>)).toList();
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de la récupération des messages.');
  }

  /// Récupère uniquement les messages dont timestamp > afterTimestamp (en secondes)
  Future<List<Message>> fetchMessagesAfter(
    String conversationId,
    double afterTimestamp,
  ) async {
    final headers = await _buildHeaders();
    final uri = Uri.parse('$_baseUrl/conversations/'
        '$conversationId/messages?after=$afterTimestamp');
    final res = await http.get(uri, headers: headers);

    if (res.statusCode == 200) {
      final List<dynamic> body = jsonDecode(res.body);
      return body
          .map((e) => Message.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    if (res.statusCode == 429) throw RateLimitException();
    throw Exception(
      'Erreur ${res.statusCode} lors de la récupération des messages récents.'
    );
  }

  /// Envoie un message chiffré via POST /messages.
  Future<Message> sendMessage({
    required String conversationId,
    required String encryptedMessage,
    required Map<String, String> encryptedKeys,
  }) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/messages');
    final String payload = jsonEncode(<String, dynamic>{
      'conversationId': conversationId,
      'encrypted_message': encryptedMessage,
      'encrypted_keys': encryptedKeys,
    });
    final http.Response response = await http.post(uri, headers: headers, body: payload);

    if (response.statusCode == 201) {
      final Map<String, dynamic> body = jsonDecode(response.body)['message'] as Map<String, dynamic>;
      return Message.fromJson(body);
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de l’envoi du message.');
  }

  // ─── V2 Messages ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> sendMessageV2({
    required Map<String, dynamic> payloadV2,
  }) async {
    final headers = await _buildHeaders();
    final uri = Uri.parse('$_baseUrl/messages');
    final body = jsonEncode(payloadV2);
    final res = await http.post(uri, headers: headers, body: body);
    if (res.statusCode == 201) {
      final Map<String, dynamic> parsed = jsonDecode(res.body) as Map<String, dynamic>;
      // backend returns { id }
      return parsed;
    }
    if (res.statusCode == 403) {
      throw Exception('403 forbidden');
    }
    if (res.statusCode == 409) {
      throw Exception('409 duplicate_messageId');
    }
    if (res.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${res.statusCode} envoi message v2');
  }

  Future<List<MessageV2Model>> fetchMessagesV2({
    required String conversationId,
    String? cursor,
    int? limit,
  }) async {
    final headers = await _buildHeaders();
    final query = <String, String>{};
    if (cursor != null) query['cursor'] = cursor;
    if (limit != null) query['limit'] = '$limit';
    final uri = Uri.parse('$_baseUrl/conversations/$conversationId/messages').replace(queryParameters: query);
    final res = await http.get(uri, headers: headers);
    if (res.statusCode == 200) {
      final Map<String, dynamic> parsed = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (parsed['items'] as List).map((e) => MessageV2Model.fromJson(e as Map<String, dynamic>)).toList();
      return items;
    }
    if (res.statusCode == 429) throw RateLimitException();
    throw Exception('Erreur ${res.statusCode} fetch messages v2');
  }

  /// Ajoute un utilisateur à une conversation via POST /conversations/:convId/users.
  Future<void> addUserToConversation({
    required String conversationId,
    required String userId,
  }) async {
    final Map<String, String> headers = await _buildHeaders();
    final Uri uri = Uri.parse('$_baseUrl/conversations/$conversationId/users');
    final String payload = jsonEncode(<String, String>{ 'userId': userId });
    final http.Response response = await http.post(uri, headers: headers, body: payload);

    if (response.statusCode == 201) {
      return;
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    throw Exception('Erreur ${response.statusCode} lors de l’ajout d’un utilisateur à la conversation.');
  }

  // ─── Read receipts ────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> postConversationRead({
    required String conversationId,
  }) async {
    final headers = await _buildHeaders();
    final uri = Uri.parse('$_baseUrl/conversations/$conversationId/read');
    final res = await http.post(uri, headers: headers);
    if (res.statusCode == 200) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    if (res.statusCode == 429) throw RateLimitException();
    throw Exception('Erreur ${res.statusCode} POST read');
  }

  Future<List<Map<String, dynamic>>> getConversationReaders({
    required String conversationId,
  }) async {
    final headers = await _buildHeaders();
    final uri = Uri.parse('$_baseUrl/conversations/$conversationId/readers');
    final res = await http.get(uri, headers: headers);
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return (body['readers'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    if (res.statusCode == 429) throw RateLimitException();
    throw Exception('Erreur ${res.statusCode} GET readers');
  }
}
