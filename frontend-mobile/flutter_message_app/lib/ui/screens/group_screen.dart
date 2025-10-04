import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/providers/group_provider.dart';
import 'package:flutter_message_app/core/services/snackbar_service.dart';
import 'package:flutter_message_app/core/crypto/key_manager_v2.dart';
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'package:flutter_message_app/core/services/api_service.dart';

class GroupScreen extends StatefulWidget {
  @override
  _GroupScreenState createState() => _GroupScreenState();
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
      final groupProvider =
          Provider.of<GroupProvider>(context, listen: false);
      
      final deviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      final groupName = _groupNameController.text.trim();
      
      // Étape 1: Créer le groupe d'abord pour obtenir le UUID
      final String groupId = await _createGroupFirst(groupName);
      
      // Étape 2: Puis générer les clés device avec le vrai UUID
      await KeyManagerV2.instance.ensureKeysFor(groupId, deviceId);
      final pubKeys = await KeyManagerV2.instance.publicKeysBase64(groupId, deviceId);
      
      // Étape 3: Publier les clés device avec le bon groupId
      await groupProvider.publishDeviceKeys(
        groupId,
        deviceId,
        pubKeys["pk_sig"]!,
        pubKeys["pk_kem"]!,
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

  /// Create group first to get UUID, then generate device keys with correct ID
  Future<String> _createGroupFirst(String groupName) async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final apiService = ApiService(authProvider);
    
    // Create group with dummy keys - we don't need real group keys for creation
    return await apiService.createGroup(
      name: groupName,
      groupSigningPubKeyB64: "dummy_group_sig_key_not_used", // Not used in backend
      groupKEMPubKeyB64: "dummy_group_kem_key_not_used",     // Not used in backend
    );
  }

  Future<void> _joinGroup() async {
    setState(() => _loading = true);
    final String groupId = _groupIdController.text.trim();
    try {
      // 🚀 CORRECTED: Utiliser directement l'UUID du groupe pour générer les clés
      final deviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      
      // Utiliser l'ID du groupe directement (pas de génération temp avec le nom)
      await KeyManagerV2.instance.ensureKeysFor(groupId, deviceId);
      final groupKeys = await KeyManagerV2.instance.publicKeysBase64(groupId, deviceId);
      
      final groupProvider =
          Provider.of<GroupProvider>(context, listen: false);
      await groupProvider.sendJoinRequest(
        groupId, 
        '', 
        groupSigningPubKeyB64: groupKeys['pk_sig']!, // Ed25519 pour signature groupe
        groupKEMPubKeyB64: groupKeys['pk_kem']!,     // X25519 pour échange groupe
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
      appBar: AppBar(
        title: Text('Groupes'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Créer un groupe',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    SizedBox(height: 16),
                    TextField(
                      controller: _groupNameController,
                      decoration: const InputDecoration(
                        labelText: 'Nom du groupe',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loading ? null : _createGroup,
                      child: _loading
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Créer'),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Rejoindre un groupe',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    SizedBox(height: 16),
                    TextField(
                      controller: _groupIdController,
                      decoration: const InputDecoration(
                        labelText: 'ID du groupe',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loading ? null : _joinGroup,
                      child: _loading
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Rejoindre'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}