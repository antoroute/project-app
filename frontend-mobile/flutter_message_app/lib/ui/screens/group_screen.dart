// Legacy RSA-based flow removed in v2
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_message_app/core/providers/group_provider.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';
import 'package:flutter_message_app/core/services/snackbar_service.dart';
import 'package:flutter_message_app/ui/screens/qr_scan_screen.dart';
import 'package:flutter_message_app/ui/screens/group_nav_screen.dart';
import 'package:flutter_message_app/ui/screens/home_screen.dart';
import 'package:flutter_message_app/config/constants.dart';

class GroupScreen extends StatefulWidget {
  const GroupScreen({Key? key}) : super(key: key);

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _groupIdController = TextEditingController();
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
      // 🚀 NOUVEAU: Générer les clés du groupe avec KeyManagerV2 (basé sur le nom du groupe)
      final auth = context.read<AuthProvider>();
      final deviceId = auth.currentDeviceId;
      if (!auth.canUseMessaging || deviceId == null) {
        throw StateError('Appareil actif requis');
      }
      final groupName = _groupNameController.text.trim();
      if (groupName.length < 3 || groupName.length > maxGroupNameCharacters) {
        SnackbarService.showError(
          context,
          'Le nom du groupe doit contenir entre 3 et $maxGroupNameCharacters caractères',
        );
        return;
      }
      if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(groupName)) {
        SnackbarService.showError(
          context,
          'Le nom du groupe contient un caractère interdit',
        );
        return;
      }

      // Utiliser le nom du groupe comme identifiant temporaire pour générer les clés groupe
      await KeyManagerFinal.instance.ensureKeysFor(groupName, deviceId);
      final groupKeys = await KeyManagerFinal.instance.publicKeysBase64(
        groupName,
        deviceId,
      );

      final groupProvider = Provider.of<GroupProvider>(context, listen: false);
      final groupId = await groupProvider.createGroupWithMembers(
        groupName: groupName,
        memberEmails: [],
        groupSigningPubKeyB64:
            groupKeys['pk_sig']!, // Ed25519 pour signature groupe
        groupKEMPubKeyB64: groupKeys['pk_kem']!, // X25519 pour échange groupe
      );

      SnackbarService.showSuccess(context, 'Groupe créé avec succès !');

      // CORRECTION: Naviguer vers la page du groupe (informations) après création
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder:
                (_) => GroupNavScreen(groupId: groupId, groupName: groupName),
          ),
        );
      }
    } catch (e) {
      SnackbarService.showError(context, 'Erreur création groupe : $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _joinGroup() async {
    setState(() => _loading = true);
    final String groupId = _groupIdController.text.trim();
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(groupId)) {
      SnackbarService.showError(context, 'Identifiant de groupe invalide');
      setState(() => _loading = false);
      return;
    }
    try {
      // 🚀 NOUVEAU: Générer les clés du groupe avec KeyManagerV2 (basé sur l'ID du groupe)
      final auth = context.read<AuthProvider>();
      final deviceId = auth.currentDeviceId;
      if (!auth.canUseMessaging || deviceId == null) {
        throw StateError('Appareil actif requis');
      }

      // Utiliser l'ID du groupe pour générer les clés groupe
      await KeyManagerFinal.instance.ensureKeysFor(groupId, deviceId);
      final groupKeys = await KeyManagerFinal.instance.publicKeysBase64(
        groupId,
        deviceId,
      );

      final groupProvider = Provider.of<GroupProvider>(context, listen: false);
      await groupProvider.sendJoinRequest(
        groupId,
        '',
        groupSigningPubKeyB64:
            groupKeys['pk_sig']!, // Ed25519 pour signature groupe
        groupKEMPubKeyB64: groupKeys['pk_kem']!, // X25519 pour échange groupe
      );

      SnackbarService.showSuccess(context, 'Demande d\'adhésion envoyée');

      // CORRECTION: Retourner à la page qui liste les groupes en attendant d'être accepté
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (route) => false, // Supprimer toutes les routes précédentes
        );
      }
    } catch (e) {
      SnackbarService.showError(context, 'Erreur demande de jointure : $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
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
              maxLength: maxGroupNameCharacters,
              decoration: const InputDecoration(labelText: 'Nom du groupe'),
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
                    maxLength: 36,
                    decoration: const InputDecoration(
                      labelText: 'ID du groupe à rejoindre',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed:
                      _loading
                          ? null
                          : () async {
                            final String? groupId =
                                await Navigator.push<String?>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const QRScanScreen(),
                                  ),
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
