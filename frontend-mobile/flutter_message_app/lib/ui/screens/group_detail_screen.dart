// Legacy creation flow code removed for v2

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
// RSA removed in v2
import 'package:flutter/services.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/services/snackbar_service.dart';
import '../../core/services/websocket_service.dart';
// Legacy creation via RSA removed in v2
import 'my_devices_screen.dart';
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
  // bool _isCreator = false; // unused in v2
  final Set<String> _selectedUserIds = {};

  // Legacy fields removed

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

    // final String? currentUserId = context.read<AuthProvider>().userId; // unused
    final groupProv = context.read<GroupProvider>();
    final convProv  = context.read<ConversationProvider>();

    try {
      debugPrint('🔄 Loading group detail for ${widget.groupId}');
      await groupProv.fetchGroupDetail(widget.groupId);
      debugPrint('✅ Group detail loaded');
      
      await groupProv.fetchGroupMembers(widget.groupId);
      debugPrint('✅ Group members loaded');
      
      await convProv.fetchConversations();
      debugPrint('✅ Conversations loaded');

      // v2: creator flag unused
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

    // 1) Compose la liste des participants (sans l'utilisateur courant, automatiquement inclus côté backend)
    final selectedUserIdsWithoutMe = _selectedUserIds.where((id) => id != currentUserId).toList();

    // 2) V2: conversation creation simple pour l'instant
    const String conversationType = 'subset'; // ou 'private' selon les besoins

    // 3) Appel à l'API
    try {
      final String newConversationId = await convProv.createConversation(
        widget.groupId,
        selectedUserIdsWithoutMe,
        conversationType,
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
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupProv = context.watch<GroupProvider>();
    final convProv  = context.watch<ConversationProvider>();
    final String? currentUserId = context.read<AuthProvider>().userId;
    
    // Debug info
    debugPrint('🔄 Group Detail - Members: ${groupProv.members.length}, Conversations: ${convProv.conversations.length}');

    // Filtre : exclut l'utilisateur courant de la liste des sélectionnables
    final members = List<Map<String, dynamic>>.from(groupProv.members)
        .where((member) => member['userId'] != currentUserId)
        .toList();
    members.sort((a, b) => (a['username'] as String).compareTo(b['username'] as String));

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
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Colors.black,
                          ),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: Colors.black,
                          ),
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

          // Bouton 'Mes appareils'
          IconButton(
            icon: const Icon(Icons.devices),
            tooltip: 'Mes appareils',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MyDevicesScreen(groupId: widget.groupId),
                ),
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

                // Section de création de conversation  
                Card(
                  margin: const EdgeInsets.all(8.0),
                  child: ExpansionTile(
                    title: Row(
                      children: [
                        const Icon(Icons.add_circle_outline, color: Colors.blue),
                        const SizedBox(width: 8),
                        const Text('💬 Créer une conversation', 
                          style: TextStyle(fontWeight: FontWeight.bold)),
                        if (_selectedUserIds.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text('${_selectedUserIds.length}', 
                              style: const TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                        ],
                      ],
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Sélectionnez les participants :', 
                              style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            const Text('(Vous êtes automatiquement inclus)', 
                              style: TextStyle(fontSize: 12, color: Colors.grey)),
                            const SizedBox(height: 12),
                            if (members.isEmpty)
                              const Card(
                                child: Padding(
                                  padding: EdgeInsets.all(16.0),
                                  child: Text('Aucun autre membre dans ce groupe', 
                                    style: TextStyle(color: Colors.grey)),
                                ),
                              )
                            else ...[
                              Container(
                                constraints: const BoxConstraints(maxHeight: 200),
                                child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: members.length,
                                  itemBuilder: (context, index) {
                                    final member = members[index];
                                    final isSelected = _selectedUserIds.contains(member['userId']);
                                    return CheckboxListTile(
                                      dense: true,
                                      title: Text(member['username'] ?? member['email'] ?? 'Utilisateur',
                                        style: const TextStyle(fontSize: 14)),
                                      subtitle: Text(member['email'] ?? '', 
                                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                      value: isSelected,
                                      onChanged: (bool? checked) {
                                        setState(() {
                                          if (checked == true) {
                                            _selectedUserIds.add(member['userId']);
                                          } else {
                                            _selectedUserIds.remove(member['userId']);
                                          }
                                        });
                                      },
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  TextButton.icon(
                                    onPressed: () => setState(() => _selectedUserIds.clear()),
                                    icon: const Icon(Icons.clear, size: 16),
                                    label: const Text('Effacer'),
                                  ),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: () => setState(() {
                                      _selectedUserIds.clear();
                                      _selectedUserIds.addAll(members.map((m) => m['userId'] as String));
                                    }),
                                    icon: const Icon(Icons.select_all, size: 16),
                                    label: const Text('Tout sélectionner'),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const Divider(height: 1),

                // Liste des conversations

                if (convs.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        const Text(
                          'Conversations',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: _loadGroupData,
                          tooltip: 'Actualiser',
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: convs.length,
                      itemBuilder: (context, index) {
                        final conv = convs[index];
                        return ListTile(
                          leading: const Icon(Icons.chat),
                          title: Text('Conversation ${conv.conversationId.substring(0, 8)}...'),
                          subtitle: Text('Type: ${conv.type}'),
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
                ] else ...[
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'Conversations',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Expanded(
                    child: Center(child: Text('Aucune conversation créée')),
                  ),
                ],
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
