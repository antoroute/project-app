import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:provider/provider.dart';

import '../../core/crypto/key_manager.dart';
import '../../core/crypto/rsa_key_utils.dart';
import '../../core/providers/auth_provider.dart';

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

    // Génération d’une paire RSA pour le nouveau groupe
    final secureRandom = pc.SecureRandom("Fortuna")
      ..seed(pc.KeyParameter(Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)))));
    final keyGen = pc.RSAKeyGenerator()
      ..init(pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 4096, 64),
        secureRandom,
      ));
    final pair = keyGen.generateKeyPair();
    final publicPem = encodePublicKeyToPem(pair.publicKey as pc.RSAPublicKey);

    // Appel API /groups
    final headers = await auth.getAuthHeaders();
    final res = await http.post(
      Uri.parse("https://api.kavalek.fr/api/groups"),
      headers: headers,
      body: jsonEncode({
        'name': _groupNameController.text.trim(),
        'publicKeyGroup': publicPem,
      }),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      final body = jsonDecode(res.body);
      final realGroupId = body['groupId'] as String;

      // Stocker localement la paire RSA pour ce groupe
      final existing = await KeyManager().getKeyPairForGroup(realGroupId);
      if (existing == null) {
        await KeyManager().storeKeyPairForGroup(realGroupId, pair);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Groupe créé avec succès !")),
      );
      Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur création groupe : ${res.body}")),
      );
    }

    setState(() => _loading = false);
  }

  Future<void> _joinGroup() async {
    setState(() => _loading = true);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final groupId = _groupIdController.text.trim();

    // Si la clé existe déjà, on est déjà membre (ou demande faite)
    final existingKey = await KeyManager().getKeyPairForGroup(groupId);
    if (existingKey != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Vous avez déjà une demande ou vous êtes membre")),
      );
      setState(() => _loading = false);
      return;
    }

    // Génération d’une paire RSA temporaire pour la demande
    final secureRandom = pc.SecureRandom("Fortuna")
      ..seed(pc.KeyParameter(Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)))));
    final keyGen = pc.RSAKeyGenerator()
      ..init(pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 4096, 64),
        secureRandom,
      ));
    final pair = keyGen.generateKeyPair();
    final publicPem = encodePublicKeyToPem(pair.publicKey as pc.RSAPublicKey);

    // Appel API /groups/:id/jjoin-request
    final headers = await auth.getAuthHeaders();
    final res = await http.post(
      Uri.parse("https://api.kavalek.fr/api/groups/$groupId/join-requests"),
      headers: headers,
      body: jsonEncode({
        'publicKeyGroup': publicPem,
      }),
    );

    if (res.statusCode == 201) {
      // Stocker la paire RSA en attente d'acceptation
      await KeyManager().storeKeyPairForGroup(groupId, pair);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Demande d’adhésion envoyée")),
      );
      Navigator.pop(context, true);
    } else {
      final msg = res.statusCode == 409
          ? 'Demande déjà en cours'
          : 'Erreur : ${res.body}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
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
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _groupIdController,
                    decoration: const InputDecoration(labelText: 'ID du groupe à rejoindre'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: 'Scanner un QR code',
                  onPressed: () async {
                    final groupId = await Navigator.push<String?>(
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

class QRScanScreen extends StatefulWidget {
  const QRScanScreen({super.key});
  @override
  State<QRScanScreen> createState() => _QRScanScreenState();
}

class _QRScanScreenState extends State<QRScanScreen> {
  bool scanned = false;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner un QR code')),
      body: MobileScanner(
        onDetect: (capture) {
          final barcodes = capture.barcodes;
          if (!scanned && barcodes.isNotEmpty && barcodes.first.rawValue != null) {
            scanned = true;
            Navigator.pop(context, barcodes.first.rawValue);
          }
        },
      ),
    );
  }
}