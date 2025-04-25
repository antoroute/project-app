import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/crypto/encryption_utils.dart';

class ConversationScreen extends StatefulWidget {
  final String conversationId;
  final String groupId;

  const ConversationScreen({super.key, required this.conversationId, required this.groupId});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _storage = const FlutterSecureStorage();
  final _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Map<String, dynamic>> _rawMessages = [];
  Map<String, String> _decryptedMessages = {};
  Map<String, bool> _verifiedSignatures = {};
  bool _loading = true;
  String? _currentUserId;
  final int _initialDecryptCount = 20;
  Map<String, String> _groupPublicKeys = {};

  Future<void> _loadMessages() async {
    final token = await _storage.read(key: 'jwt');

    final resUser = await http.get(
      Uri.parse('https://auth.kavalek.fr/auth/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resUser.statusCode == 200) {
      final data = jsonDecode(resUser.body);
      _currentUserId = data['user']['id'];
    }

    final res = await http.get(
      Uri.parse('https://api.kavalek.fr/api/conversations/${widget.conversationId}/messages'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final messages = List<Map<String, dynamic>>.from(data);
      setState(() => _rawMessages = messages.reversed.toList());
      await _decryptVisibleMessages();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur chargement messages: ${res.body}')),
      );
    }
    setState(() => _loading = false);
  }

  Future<void> _decryptVisibleMessages() async {
    for (int i = 0; i < _rawMessages.length && i < _initialDecryptCount; i++) {
      final m = _rawMessages[i];
      if (_decryptedMessages.containsKey(m['id'])) continue;

      try {
        final decrypted = await EncryptionUtils.decryptMessageFromPayload(
          groupId: widget.groupId,
          encrypted: m['encrypted'],
          iv: m['iv'],
          encryptedKeyForCurrentUser: m['keys'][_currentUserId],
        );
        _decryptedMessages[m['id']] = decrypted;

        if (m['signature'] != null && m['senderPublicKey'] != null) {
          final valid = await EncryptionUtils.verifySignature(
            payload: m,
            signature: m['signature'],
            senderPublicKeyPem: m['senderPublicKey'],
          );
          _verifiedSignatures[m['id']] = valid;
        }
      } catch (_) {
        _decryptedMessages[m['id']] = '[Déchiffrement impossible]';
      }
    }
    setState(() {});
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();

    final token = await _storage.read(key: 'jwt');

    final resMembers = await http.get(
      Uri.parse('https://api.kavalek.fr/api/groups/${widget.groupId}/members'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (resMembers.statusCode != 200) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur récupération clés: ${resMembers.body}')),
      );
      return;
    }

    final members = List<Map<String, dynamic>>.from(jsonDecode(resMembers.body));
    final publicKeys = <String, String>{
      for (var m in members)
        m['userId'].toString(): m['publicKeyGroup'].toString()
    };

    final payload = await EncryptionUtils.encryptMessageForUsers(
      groupId: widget.groupId,
      plaintext: text,
      publicKeysByUserId: publicKeys,
    );

    final res = await http.post(
      Uri.parse('https://api.kavalek.fr/api/conversations/${widget.conversationId}/messages'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(payload),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      await _loadMessages();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur envoi: ${res.body}')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _scrollController.addListener(() async {
      if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent) {
        await _decryptVisibleMessages();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conversation')),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    itemCount: _rawMessages.length,
                    itemBuilder: (context, index) {
                      final msg = _rawMessages[index];
                      final decrypted = _decryptedMessages[msg['id']] ?? '[En attente de déchiffrement]';
                      final verified = _verifiedSignatures[msg['id']];
                      final icon = verified == null
                          ? null
                          : verified
                              ? const Icon(Icons.verified, color: Colors.green)
                              : const Icon(Icons.warning_amber, color: Colors.redAccent);
                      return ListTile(
                        title: Text(msg['senderId'] ?? 'Inconnu'),
                        subtitle: Text(decrypted),
                        trailing: icon,
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(hintText: 'Votre message...'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}