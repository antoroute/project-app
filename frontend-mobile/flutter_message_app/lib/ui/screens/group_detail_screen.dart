import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:flutter/services.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/services/snackbar_service.dart';
import '../../core/services/websocket_service.dart';
import '../../core/crypto/aes_utils.dart';
import '../../core/crypto/rsa_key_utils.dart';
import '../../core/crypto/key_manager.dart';
import 'join_requests_screen.dart';
import 'conversation_screen.dart';

/// Écran de détail d’un groupe : liste des conversations et création de conversation.
class GroupDetailScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupDetailScreen({
    Key? key,
    required this.groupId,
    required this.groupName,
  }) : super(key: key);

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  bool _loading = true;
  bool _isCreator = false;
  final Set<String> _selectedUserIds = {};

  Uint8List? _cachedAESKey;
  Map<String, String>? _cachedEncryptedSecrets;
  String? _cachedSignature;

  @override
  void initState() {
    super.initState();
    _loadGroupData();
    WebSocketService.instance.onGroupJoined = () {
      if (mounted) {
        _loadGroupData();
        SnackbarService.showInfo(
          context,
          'Vous avez rejoint un nouveau groupe',
        );
      }
    };
  }

  Future<void> _loadGroupData() async {
    setState(() => _loading = true);

    final String? currentUserId = context.read<AuthProvider>().userId;
    final groupProv = context.read<GroupProvider>();
    final convProv  = context.read<ConversationProvider>();

    try {
      await groupProv.fetchGroupDetail(widget.groupId);
      await groupProv.fetchGroupMembers(widget.groupId);
      await convProv.fetchConversations();

      // Détermine si l’utilisateur courant est le créateur
      final creatorId = groupProv.groupDetail?['creator_id'] as String?;
      _isCreator = currentUserId != null && creatorId == currentUserId;
    } catch (error) {
      SnackbarService.showError(
        context,
        'Erreur chargement : $error',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createConversation() async {
    final String? currentUserId = context.read<AuthProvider>().userId;
    if (currentUserId == null) {
      SnackbarService.showError(context, 'Utilisateur non authentifié');
      return;
    }

    final convProv = context.read<ConversationProvider>();
    final groupProv = context.read<GroupProvider>();

    // 1) Compose la liste des participants
    final participants = Set<String>.from(_selectedUserIds)..add(currentUserId);

    // 2) Prépare l’enveloppe chiffrée
    if (_cachedAESKey == null || _cachedEncryptedSecrets == null) {
      // Génère une clé AES
      _cachedAESKey = AesUtils.generateRandomAESKey();
      final Map<String, String> secrets = {};

      // Chiffre la clé AES pour chaque participant
      for (final uid in participants) {
        final member = groupProv.members.firstWhere(
          (m) => m['userId'] == uid,
          orElse: () => <String, dynamic>{},
        );
        final String? pem = member['publicKeyGroup'] as String?;
        if (pem == null) {
          throw Exception('Clé publique absente pour $uid');
        }
        final Uint8List cipherBytes =
            RsaKeyUtils.encryptAESKeyWithRSAOAEP(pem, _cachedAESKey!);
        secrets[uid] = base64.encode(cipherBytes);
      }
      _cachedEncryptedSecrets = secrets;

      // Récupère la clé privée du groupe pour signer
      final kp = await KeyManager().getKeyPairForGroup(widget.groupId);
      if (kp == null) {
        throw Exception('Clé privée du groupe manquante');
      }
      final signer = pc.Signer('SHA-256/RSA')
        ..init(
          true,
          pc.PrivateKeyParameter<pc.RSAPrivateKey>(kp.privateKey as pc.RSAPrivateKey),
        );

      // Signature de l’enveloppe JSON
      final String payload = jsonEncode(_cachedEncryptedSecrets);
      final pc.RSASignature signature = signer
          .generateSignature(Uint8List.fromList(utf8.encode(payload)))
        as pc.RSASignature;
      _cachedSignature = base64.encode(signature.bytes);
    }

    // 3) Appel à l’API
    try {
      final String newConversationId = await convProv.createConversation(
        widget.groupId,
        participants.toList(),
        _cachedEncryptedSecrets!,
        _cachedSignature!,
      );
      SnackbarService.showSuccess(context, 'Conversation créée !');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ConversationScreen(
            conversationId: newConversationId,
          ),
        ),
      );
    } catch (error) {
      SnackbarService.showError(context, 'Erreur création : $error');
    } finally {
      // Réinitialisation
      setState(() {
        _selectedUserIds.clear();
        _cachedAESKey = null;
        _cachedEncryptedSecrets = null;
        _cachedSignature = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupProv = context.watch<GroupProvider>();
    final convProv  = context.watch<ConversationProvider>();
    final String? currentUserId = context.read<AuthProvider>().userId;

    // Trie : place l’utilisateur courant en dernier
    final members = List<Map<String, dynamic>>.from(groupProv.members);
    members.sort((a, b) {
      if (a['userId'] == currentUserId) return 1;
      if (b['userId'] == currentUserId) return -1;
      return 0;
    });

    // Filtre des conversations du groupe
    final convs = convProv.conversations
        .where((c) => c.groupId == widget.groupId)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.groupName),
        actions: [
          // Bouton QR code
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'Voir QR code',
            onPressed: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (bottomCtx) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        QrImageView(
                          data: widget.groupId,
                          version: QrVersions.auto,
                          size: 200.0,
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  const Text(
                                    'ID du groupe',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.black,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.groupId,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Colors.black,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy),
                              color: Colors.black,
                              tooltip: 'Copier l’ID',
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: widget.groupId),
                                );
                                Navigator.of(bottomCtx).pop();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('ID copié !')),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          child: const Text('FERMER'),
                          onPressed: () => Navigator.of(bottomCtx).pop(),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),

          // Bouton demandes d’adhésion
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
                    isCreator: true,
                  ),
                ),
              ).then((_) {
                // Recharger après retour
                _loadGroupData();
              });
            },
          ),
        ],
      ),

      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const Divider(height: 1),

                // Liste des conversations
                if (convs.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'Conversations',
                      style: TextStyle(fontSize: 18),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: convs.length,
                      itemBuilder: (context, index) {
                        final conv = convs[index];
                        return ListTile(
                          title: Text('Conversation ${conv.conversationId}'),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ConversationScreen(
                                  conversationId: conv.conversationId,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ] else
                  const Expanded(
                    child: Center(child: Text('Aucune conversation')),
                  ),

                const Divider(height: 1),

                // Sélecteur d’utilisateurs pour créer une conversation
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'Créer une nouvelle conversation',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: members.length,
                    itemBuilder: (context, index) {
                      final member = members[index];
                      final String userId = member['userId'] as String;
                      final String username =
                          member['username'] as String? ?? 'Utilisateur';
                      final bool isSelf = userId == currentUserId;

                      return CheckboxListTile(
                        title: Text(username),
                        subtitle: Text(member['email'] as String? ?? ''),
                        value: _selectedUserIds.contains(userId),
                        onChanged: isSelf
                            ? null
                            : (bool? selected) {
                                setState(() {
                                  if (selected == true) {
                                    _selectedUserIds.add(userId);
                                  } else {
                                    _selectedUserIds.remove(userId);
                                  }
                                });
                              },
                      );
                    },
                  ),
                ),
              ],
            ),

      floatingActionButton: _selectedUserIds.isNotEmpty
          ? FloatingActionButton(
              onPressed: _createConversation,
              child: const Icon(Icons.chat),
              tooltip: 'Créer conversation',
            )
          : null,
    );
  }
}
