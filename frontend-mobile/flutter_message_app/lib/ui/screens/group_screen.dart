import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;
import 'package:provider/provider.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/crypto/key_manager.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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

    final keyGen = pc.RSAKeyGenerator()
      ..init(pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 4096, 64),
        pc.SecureRandom("Fortuna")
          ..seed(pc.KeyParameter(Uint8List.fromList(List.generate(32, (_) => 42))))
      ));
    final pair = keyGen.generateKeyPair();
    final publicPem = encodePublicKeyToPem(pair.publicKey as pc.RSAPublicKey);

    final res = await http.post(
      Uri.parse("https://api.kavalek.fr/api/groups"),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${auth.token}'
      },
      body: jsonEncode({
        'name': _groupNameController.text.trim(),
        'publicKeyGroup': publicPem,
      }),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      final groupData = jsonDecode(res.body);
      final realGroupId = groupData['groupId'];

      final existingKey = await KeyManager().getKeyPairForGroup(realGroupId);
      if (existingKey != null) {
        print('🔵 Clé déjà existante pour ce groupe, pas de régénération.');
      } else {
        await KeyManager().storeKeyPairForGroup(realGroupId, pair);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Groupe créé avec succès !")),
      );

      Navigator.pop(context, true);
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

    final existingKey = await KeyManager().getKeyPairForGroup(groupId);
    if (existingKey != null) {
      print('🔵 Clé déjà existante pour ce groupe, pas de régénération.');
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Déjà membre de ce groupe !")),
      );
      return;
    }

    final keyGen = pc.RSAKeyGenerator()
      ..init(pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 4096, 64),
        pc.SecureRandom("Fortuna")
          ..seed(pc.KeyParameter(Uint8List.fromList(List.generate(32, (_) => 42))))
      ));
    final pair = keyGen.generateKeyPair();
    final publicPem = encodePublicKeyToPem(pair.publicKey as pc.RSAPublicKey);

    final res = await http.post(
      Uri.parse("https://api.kavalek.fr/api/groups/$groupId/join"),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${auth.token}'
      },
      body: jsonEncode({
        'publicKeyGroup': publicPem,
      }),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      await KeyManager().storeKeyPairForGroup(groupId, pair);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Rejoint avec succès !")),
      );

      Navigator.pop(context, true);
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
                    final groupId = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const QRScanScreen(),
                      ),
                    );
                    if (groupId != null && groupId is String) {
                      setState(() {
                        _groupIdController.text = groupId;
                      });
                    }
                  },
                ),
              ],
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
          final List<Barcode> barcodes = capture.barcodes;
          if (!scanned && barcodes.isNotEmpty && barcodes.first.rawValue != null) {
            scanned = true;
            Navigator.pop(context, barcodes.first.rawValue);
          }
        },
      ),
    );
  }
}
