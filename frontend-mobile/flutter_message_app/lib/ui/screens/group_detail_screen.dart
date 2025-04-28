import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;
import 'package:provider/provider.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/crypto/key_manager.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/crypto/encryption_utils.dart';
import 'conversation_screen.dart';

class GroupDetailScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupDetailScreen({super.key, required this.groupId, required this.groupName});

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  List<Map<String, dynamic>> _members = [];
  final Set<String> _selectedUserIds = {};
  bool _loading = true;
  String? _currentUserId;

  Future<void> _fetchGroupMembers() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    if (token == null) throw Exception('Token JWT manquant');

    final resUser = await http.get(
      Uri.parse('https://auth.kavalek.fr/auth/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resUser.statusCode == 200) {
      final data = jsonDecode(resUser.body);
      _currentUserId = data['user']['id'];
    }

    final res = await http.get(
      Uri.parse('https://api.kavalek.fr/api/groups/${widget.groupId}/members'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final allMembers = List<Map<String, dynamic>>.from(data);
      final sorted = [
        ...allMembers.where((m) => m['userId'] != _currentUserId),
        ...allMembers.where((m) => m['userId'] == _currentUserId),
      ];
      setState(() => _members = sorted);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur membres: ${res.body}')),
      );
    }
    setState(() => _loading = false);
  }

  Future<void> _createConversation() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    if (token == null) throw Exception('Token JWT manquant');

    final Map<String, String> encryptedSecrets = {};

    for (final userId in _selectedUserIds) {
      final member = _members.firstWhere((m) => m['userId'] == userId);
      final publicKeyPem = member['publicKeyGroup'];

      final aesKey = EncryptionUtils.generateRandomAESKey();

      final encrypted = EncryptionUtils.encryptAESKeyWithRSAOAEP(publicKeyPem, aesKey);
      encryptedSecrets[userId] = base64.encode(encrypted);
    }

    // Signature de encryptedSecrets
    final aesSecretJson = jsonEncode(encryptedSecrets);

    final keyPair = await KeyManager().getKeyPairForGroup('user_rsa');
    if (keyPair == null) throw Exception('Clé privée RSA manquante');

    final signer = pc.Signer('SHA-256/RSA')
      ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(keyPair.privateKey as pc.RSAPrivateKey));

    final signature = signer.generateSignature(utf8.encode(aesSecretJson) as Uint8List) as pc.RSASignature;
    final creatorSignature = base64.encode(signature.bytes);

    final res = await http.post(
      Uri.parse("https://api.kavalek.fr/api/conversations"),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token'
      },
      body: jsonEncode({
        'groupId': widget.groupId,
        'userIds': _selectedUserIds.toList(),
        'encryptedSecrets': encryptedSecrets,
        'creatorSignature': creatorSignature,
      }),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Conversation créée !")),
      );
      await Provider.of<ConversationProvider>(context, listen: false).fetchConversations(context);
      setState(() => _selectedUserIds.clear());
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur création: ${res.body}")),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _fetchGroupMembers();
  }

  @override
  Widget build(BuildContext context) {
    final conversations = Provider.of<ConversationProvider>(context).getConversationsForGroup(widget.groupId);

    return Scaffold(
      appBar: AppBar(title: Text(widget.groupName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('Conversations', style: TextStyle(fontSize: 18)),
                      ),
                      ...conversations.map((c) => ListTile(
                            title: Text(c['type'] == 'subset' ? 'Conversation de groupe' : 'Conversation privée'),
                            subtitle: Text('ID: ${c['conversationId']}'),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ConversationScreen(
                                  conversationId: c['conversationId'],
                                  groupId: widget.groupId,
                                ),
                              ),
                            ),
                          )),
                      const Divider(),
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('Créer une nouvelle conversation', style: TextStyle(fontSize: 18)),
                      ),
                      ..._members.map((m) {
                        final isSelf = m['userId'] == _currentUserId;
                        return CheckboxListTile(
                          title: Text(m['username'] ?? 'Utilisateur inconnu'),
                          subtitle: Text(m['email']),
                          value: _selectedUserIds.contains(m['userId']),
                          onChanged: isSelf
                              ? null
                              : (bool? selected) {
                                  setState(() {
                                    if (selected == true) {
                                      _selectedUserIds.add(m['userId']);
                                    } else {
                                      _selectedUserIds.remove(m['userId']);
                                    }
                                  });
                                },
                        );
                      }),
                      if (_selectedUserIds.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: ElevatedButton(
                            onPressed: _createConversation,
                            child: const Text('Créer la conversation'),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}