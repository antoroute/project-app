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
import '../../core/crypto/aes_utils.dart';
import '../../core/crypto/rsa_key_utils.dart';
import 'conversation_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';

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

  // ➔ Variables pour cacher l'AES, signature et encryptedSecrets
  Uint8List? _cachedAESKey;
  String? _cachedSignature;
  Map<String, String>? _cachedEncryptedSecrets;

  // Cache des membres par conversationId
  final Map<String, List<Map<String, dynamic>>> _conversationMembers = {};
  final Set<String> _loadingConversations = {};

  bool _didFetchConversations = false;

  @override
  void initState() {
    super.initState();
    _fetchGroupMembers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didFetchConversations) {
      Provider.of<ConversationProvider>(context, listen: false).fetchConversations(context);
      _didFetchConversations = true;
    }
  }

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

  Future<void> _fetchConversationMembers(String conversationId) async {
    if (_conversationMembers.containsKey(conversationId) || _loadingConversations.contains(conversationId)) return;
    _loadingConversations.add(conversationId);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    if (token == null) return;
    try {
      final res = await http.get(
        Uri.parse('https://api.kavalek.fr/api/conversations/$conversationId/members'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final data = List<Map<String, dynamic>>.from(jsonDecode(res.body));
        setState(() {
          _conversationMembers[conversationId] = data;
        });
      }
    } catch (_) {}
    _loadingConversations.remove(conversationId);
  }

  Future<void> _createConversation() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    if (token == null) throw Exception('Token JWT manquant');

    final Set<String> participantIds = {..._selectedUserIds};
    if (_currentUserId != null) {
      participantIds.add(_currentUserId!);
    }

    // ➔ Si pas encore généré, on génère AES, encryptedSecrets et signature
    if (_cachedAESKey == null || _cachedEncryptedSecrets == null) {
      _cachedAESKey = AesUtils.generateRandomAESKey();
      final Map<String, String> encryptedSecrets = {};

      for (final userId in participantIds) {
        final member = _members.firstWhere((m) => m['userId'] == userId, orElse: () => {});
        final publicKeyPem = member['publicKeyGroup'];

        if (publicKeyPem == null) {
          throw Exception('❌ Clé publique absente pour userId $userId');
        }

        final encrypted = RsaKeyUtils.encryptAESKeyWithRSAOAEP(publicKeyPem, _cachedAESKey!);
        encryptedSecrets[userId] = base64.encode(encrypted);
      }

      _cachedEncryptedSecrets = encryptedSecrets;

      final keyPair = await KeyManager().getKeyPairForGroup('user_rsa');
      if (keyPair == null) throw Exception('Clé privée RSA manquante');

      final signer = pc.Signer('SHA-256/RSA')
        ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(keyPair.privateKey as pc.RSAPrivateKey));

      final signature = signer.generateSignature(Uint8List.fromList(utf8.encode(jsonEncode(encryptedSecrets)))) as pc.RSASignature;
      _cachedSignature = base64.encode(signature.bytes);
    }

    final res = await http.post(
      Uri.parse("https://api.kavalek.fr/api/conversations"),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token'
      },
      body: jsonEncode({
        'groupId': widget.groupId,
        'userIds': _selectedUserIds.toList(),
        'encryptedSecrets': _cachedEncryptedSecrets,
        'creatorSignature': _cachedSignature,
      }),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Conversation créée !")),
      );
      await Provider.of<ConversationProvider>(context, listen: false).fetchConversations(context);
      setState(() {
        _selectedUserIds.clear();
        _cachedAESKey = null;
        _cachedEncryptedSecrets = null;
        _cachedSignature = null;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur création: ${res.body}")),
      );
    }
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
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 8),
                  child: Column(
                    children: [
                      QrImageView(
                        data: widget.groupId,
                        version: QrVersions.auto,
                        size: 120.0,
                        backgroundColor: Colors.white,
                      ),
                      const SizedBox(height: 6),
                      Text('ID du groupe : ${widget.groupId}', style: const TextStyle(fontSize: 13, color: Colors.grey)),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('Conversations', style: TextStyle(fontSize: 18)),
                      ),
                      ...conversations.map((c) {
                        final conversationId = c['conversationId'];
                        final members = _conversationMembers[conversationId];
                        if (members == null) {
                          // Lancer le chargement si pas déjà fait
                          _fetchConversationMembers(conversationId);
                        }
                        final otherUsernames = members == null
                            ? null
                            : members
                                .where((m) => m['userId'] != _currentUserId)
                                .map((m) => m['username'] ?? 'Inconnu')
                                .toList();
                        final title = otherUsernames == null
                            ? 'Chargement...'
                            : (otherUsernames.isNotEmpty ? otherUsernames.join(', ') : 'Conversation');
                        return ListTile(
                          title: Text(title),
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
                        );
                      }),
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
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: ElevatedButton(
                          onPressed: _selectedUserIds.isNotEmpty ? _createConversation : null,
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