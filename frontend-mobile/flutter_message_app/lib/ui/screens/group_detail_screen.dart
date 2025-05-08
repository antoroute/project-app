import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'; 
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/crypto/crypto_tasks.dart';         
import '../../core/crypto/key_manager.dart';
import '../../core/crypto/rsa_key_utils.dart';
import '../../core/crypto/aes_utils.dart';
import '../../core/crypto/encryption_utils.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/services/snackbar_service.dart';
import 'conversation_screen.dart';
import 'join_requests_screen.dart';

class GroupDetailScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupDetailScreen({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  List<Map<String, dynamic>> _members = [];
  Map<String, List<Map<String, dynamic>>> _conversationMembers = {};
  final Set<String> _loadingConversations = {};
  final Set<String> _selectedUserIds = {};

  bool _loading = true;
  bool _loadingCreator = true;
  bool _isCreator = false;
  String? _currentUserId;

  Uint8List? _cachedAESKey;
  String? _cachedSignature;
  Map<String, String>? _cachedEncryptedSecrets;

  @override
  void initState() {
    super.initState();
    _checkCreator();
    _ensureGroupKey();
    _fetchGroupMembers();
  }

  Future<void> _checkCreator() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token!;
    // 1) Récupère l’ID courant
    final meRes = await http.get(
      Uri.parse('https://auth.kavalek.fr/auth/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (meRes.statusCode != 200) {
      throw Exception('Impossible de récupérer l’utilisateur');
    }
    final me = jsonDecode(meRes.body)['user'];
    final currentUserId = me['id'] as String;

    // 2) Récupère les infos du groupe (y compris creator_id)
    final grpRes = await http.get(
      Uri.parse('https://api.kavalek.fr/api/groups/${widget.groupId}'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (grpRes.statusCode != 200) {
      throw Exception('Impossible de récupérer le groupe');
    }
    final info = jsonDecode(grpRes.body);
    final creatorId = info['creator_id'] as String;

    // 3) Compare
    setState(() {
      _currentUserId = currentUserId;
      _isCreator = creatorId == currentUserId;
      _loadingCreator = false;
    });
  }

  Future<void> _ensureGroupKey() async {
    final existing = await KeyManager().getKeyPairForGroup(widget.groupId);
    if (existing == null) {
      // 1) Generate key pair off main thread
      final pair = await compute(generateRsaKeyPairTask, null);
      // 2) Store locally
      await KeyManager().storeKeyPairForGroup(widget.groupId, pair);

      // 3) Encode public key
      final publicPem = RsaKeyUtils.encodePublicKeyToPem(
        pair.publicKey as pc.RSAPublicKey,
      );

      // 4) Send join-request to update key
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final headers = await auth.getAuthHeaders();
      final res = await http.post(
        Uri.parse(
          'https://api.kavalek.fr/api/groups/${widget.groupId}/join-requests',
        ),
        headers: headers,
        body: jsonEncode({'publicKeyGroup': publicPem}),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        SnackbarService.showSuccess(
          context,
          'Clé absente : demande de mise à jour envoyée au créateur.',
        );
      } else {
        SnackbarService.showError(
          context,
          'Erreur demande mise à jour clé : ${res.body}',
        );
      }
    }
  }

  Future<void> _fetchGroupMembers() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token!;
    // get my userId
    final me = await http.get(
      Uri.parse('https://auth.kavalek.fr/auth/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (me.statusCode == 200) {
      _currentUserId = jsonDecode(me.body)['user']['id'] as String?;
    }

    final res = await http.get(
      Uri.parse('https://api.kavalek.fr/api/groups/${widget.groupId}/members'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode == 200) {
      final data = List<Map<String, dynamic>>.from(jsonDecode(res.body));
      // sort: others first, me last
      final sorted = [
        ...data.where((m) => m['userId'] != _currentUserId),
        ...data.where((m) => m['userId'] == _currentUserId),
      ];
      setState(() => _members = sorted);
    } else {
      SnackbarService.showError(context, 'Erreur membres: ${res.body}');
    }
    setState(() => _loading = false);
  }

  Future<void> _fetchConversationMembers(String convId) async {
    if (_conversationMembers.containsKey(convId) ||
        _loadingConversations.contains(convId)) return;
    _loadingConversations.add(convId);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token!;
    final res = await http.get(
      Uri.parse('https://api.kavalek.fr/api/conversations/$convId/members'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode == 200) {
      final list = List<Map<String, dynamic>>.from(jsonDecode(res.body));
      setState(() {
        _conversationMembers[convId] = list;
      });
    }
    _loadingConversations.remove(convId);
  }

  Future<void> _createConversation() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token!;
    final participants = {..._selectedUserIds};
    if (_currentUserId != null) participants.add(_currentUserId!);

    if (_cachedAESKey == null || _cachedEncryptedSecrets == null) {
      _cachedAESKey = AesUtils.generateRandomAESKey();
      final secrets = <String, String>{};
      for (final uid in participants) {
        final member = _members.firstWhere((m) => m['userId'] == uid,
            orElse: () => {});
        final pem = member['publicKeyGroup'] as String?;
        if (pem == null) throw Exception('Clé publique absente pour $uid');
        final ct = RsaKeyUtils.encryptAESKeyWithRSAOAEP(pem, _cachedAESKey!);
        secrets[uid] = base64.encode(ct);
      }
      _cachedEncryptedSecrets = secrets;

      final kp = await KeyManager().getKeyPairForGroup(widget.groupId);
      if (kp == null) throw Exception('Clé privée groupe manquante');
      final signer = pc.Signer('SHA-256/RSA')
        ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(
            kp.privateKey as pc.RSAPrivateKey));
      final payload = jsonEncode(_cachedEncryptedSecrets);
      final sig = signer
          .generateSignature(Uint8List.fromList(utf8.encode(payload)))
          as pc.RSASignature;
      _cachedSignature = base64.encode(sig.bytes);
    }
    final headers = await auth.getAuthHeaders();
    final res = await http.post(
      Uri.parse('https://api.kavalek.fr/api/conversations'),
      headers: headers,
      body: jsonEncode({
        'groupId': widget.groupId,
        'userIds': _selectedUserIds.toList(),
        'encryptedSecrets': _cachedEncryptedSecrets,
        'creatorSignature': _cachedSignature,
      }),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      SnackbarService.showSuccess(context, 'Conversation créée !');
      await Provider.of<ConversationProvider>(context, listen: false)
          .fetchConversations(context);
      setState(() {
        _selectedUserIds.clear();
        _cachedAESKey = null;
        _cachedEncryptedSecrets = null;
        _cachedSignature = null;
      });
    } else {
      SnackbarService.showError(context, 'Erreur création: ${res.body}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _loadingCreator) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final convs = Provider.of<ConversationProvider>(context)
        .getConversationsForGroup(widget.groupId);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.groupName),
        actions: [
          IconButton(
            icon: const Icon(Icons.how_to_reg),
            tooltip: 'Demandes d’adhésion',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => JoinRequestsScreen(
                    groupId: widget.groupId,
                    groupName: widget.groupName,
                    isCreator: _isCreator,
                  ),
                ),
              );
            },
          )
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Column(
              children: [
                QrImageView(
                  data: widget.groupId,
                  version: QrVersions.auto,
                  size: 120,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 6),
                Text(
                  'ID du groupe : ${widget.groupId}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Conversations',
                      style: TextStyle(fontSize: 18)),
                ),
                ...convs.map((c) {
                  final convId = c['conversationId'] as String;
                  final members = _conversationMembers[convId];
                  if (members == null) _fetchConversationMembers(convId);
                  final title = members
                          ?.where((m) => m['userId'] != _currentUserId)
                          .map((m) => m['username'] ?? '')
                          .join(', ') ??
                      'Chargement...';
                  return ListTile(
                    title: Text(title),
                    subtitle: Text('ID: $convId'),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ConversationScreen(
                          conversationId: convId,
                          groupId: widget.groupId,
                        ),
                      ),
                    ),
                  );
                }),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Créer une nouvelle conversation',
                      style: TextStyle(fontSize: 18)),
                ),
                ..._members.map((m) {
                  final isSelf = m['userId'] == _currentUserId;
                  return CheckboxListTile(
                    title: Text(m['username'] ?? 'Utilisateur'),
                    subtitle: Text(m['email']),
                    value: _selectedUserIds.contains(m['userId']),
                    onChanged: isSelf
                        ? null
                        : (sel) {
                            setState(() {
                              if (sel == true) {
                                _selectedUserIds.add(m['userId']);
                              } else {
                                _selectedUserIds.remove(m['userId']);
                              }
                            });
                          },
                  );
                }),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: ElevatedButton(
                    onPressed: _selectedUserIds.isNotEmpty
                        ? _createConversation
                        : null,
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
