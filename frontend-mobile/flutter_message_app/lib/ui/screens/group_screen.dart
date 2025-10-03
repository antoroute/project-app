// Legacy RSA-based flow removed in v2
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_message_app/core/providers/group_provider.dart';
import 'package:flutter_message_app/core/services/group_key_service.dart';
import 'package:flutter_message_app/core/services/snackbar_service.dart';
import 'package:flutter_message_app/ui/screens/qr_scan_screen.dart';

class GroupScreen extends StatefulWidget {
  const GroupScreen({Key? key}) : super(key: key);

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _groupIdController   = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _groupNameController.dispose();
    _groupIdController.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    setState(() => _loading = true);
    try {
      // Générer les clés du groupe pour la v2
      final groupSigningPubKey = await GroupKeyService.instance.getGroupSigningPublicKeyB64(_groupNameController.text.trim());
      final groupKEMPubKey = await GroupKeyService.instance.getGroupKEMPublicKeyB64(_groupNameController.text.trim());
      
      final groupProvider =
          Provider.of<GroupProvider>(context, listen: false);
      await groupProvider.createGroupWithMembers(
        groupName: _groupNameController.text.trim(),
        memberEmails: [],
        groupSigningPubKeyB64: groupSigningPubKey,
        groupKEMPubKeyB64: groupKEMPubKey,
      );

      SnackbarService.showSuccess(
          context, 'Groupe créé avec succès !');
      Navigator.pop(context, true);
    } catch (e) {
      SnackbarService.showError(
          context, 'Erreur création groupe : $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _joinGroup() async {
    setState(() => _loading = true);
    final String groupId = _groupIdController.text.trim();
    try {
      // Générer les clés du groupe pour la v2
      final groupSigningPubKey = await GroupKeyService.instance.getGroupSigningPublicKeyB64(groupId);
      final groupKEMPubKey = await GroupKeyService.instance.getGroupKEMPublicKeyB64(groupId);
      
      final groupProvider =
          Provider.of<GroupProvider>(context, listen: false);
      await groupProvider.sendJoinRequest(
        groupId, 
        '', 
        groupSigningPubKeyB64: groupSigningPubKey,
        groupKEMPubKeyB64: groupKEMPubKey,
      );

      SnackbarService.showSuccess(
          context, 'Demande d\'adhésion envoyée');
      Navigator.pop(context, true);
    } catch (e) {
      SnackbarService.showError(
          context, 'Erreur demande de jointure : $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Groupes")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            TextField(
              controller: _groupNameController,
              decoration:
                  const InputDecoration(labelText: 'Nom du groupe'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _loading ? null : _createGroup,
              child: const Text('Créer un groupe'),
            ),
            const Divider(height: 32),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _groupIdController,
                    decoration: const InputDecoration(
                      labelText: 'ID du groupe à rejoindre',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: _loading
                      ? null
                      : () async {
                          final String? groupId = await Navigator.push<String?>(
                            context,
                            MaterialPageRoute(builder: (_) => const QRScanScreen()),
                          );
                          if (groupId != null && groupId.isNotEmpty) {
                            setState(() => _groupIdController.text = groupId);
                          }
                        },
                ),
              ],
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _loading ? null : _joinGroup,
              child: const Text('Demander à rejoindre un groupe'),
            ),
          ],
        ),
      ),
    );
  }
}
