import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart';
import 'package:provider/provider.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/crypto/key_manager.dart';

class GroupScreen extends StatefulWidget {
  const GroupScreen({super.key});

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  final _groupNameController = TextEditingController();
  final _groupIdController = TextEditingController();
  bool _loading = false;

  Future<void> _createGroup() async {
    setState(() => _loading = true);
    final auth = Provider.of<AuthProvider>(context, listen: false);

    // Génère et stocke une paire RSA pour ce groupe
    final groupId = UniqueKey().toString();
    await KeyManager().generateKeyPairForGroup(groupId);
    final pair = await KeyManager().getKeyPairForGroup(groupId);
    final pubPem = encodePublicKeyToPem(pair!.publicKey as pc.RSAPublicKey);

    final res = await http.post(
      Uri.parse("https://api.kavalek.fr/api/groups"),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${auth.token}'
      },
      body: jsonEncode({
        'name': _groupNameController.text.trim(),
        'publicKeyGroup': pubPem,
      }),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Groupe créé avec succès !")),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur création groupe: ${res.body}")),
      );
    }

    setState(() => _loading = false);
  }

  Future<void> _joinGroup() async {
    setState(() => _loading = true);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final groupId = _groupIdController.text.trim();

    // Génère et stocke une paire RSA pour le groupe
    await KeyManager().generateKeyPairForGroup(groupId);
    final pair = await KeyManager().getKeyPairForGroup(groupId);
    final pubPem = encodePublicKeyToPem(pair!.publicKey as pc.RSAPublicKey);

    final res = await http.post(
      Uri.parse("https://api.kavalek.fr/api/groups/$groupId/join"),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${auth.token}'
      },
      body: jsonEncode({
        'publicKeyGroup': pubPem,
      }),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Rejoint avec succès !")),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur join: ${res.body}")),
      );
    }

    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Groupes")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _groupNameController,
              decoration: const InputDecoration(labelText: 'Nom du groupe'),
            ),
            ElevatedButton(
              onPressed: _loading ? null : _createGroup,
              child: const Text('Créer un groupe'),
            ),
            const Divider(),
            TextField(
              controller: _groupIdController,
              decoration: const InputDecoration(labelText: 'ID du groupe à rejoindre'),
            ),
            ElevatedButton(
              onPressed: _loading ? null : _joinGroup,
              child: const Text('Rejoindre un groupe'),
            ),
          ],
        ),
      ),
    );
  }
}
