import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:flutter_message_app/core/providers/group_provider.dart';
import 'package:flutter_message_app/core/services/snackbar_service.dart';
import 'package:flutter_message_app/core/crypto/key_manager.dart';
import 'package:flutter_message_app/core/crypto/rsa_key_utils.dart';
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
      // 1. Génération d’un SecureRandom
      final secureRandom = pc.FortunaRandom();
      secureRandom.seed(pc.KeyParameter(
        Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        ),
      ));
      // 2. Génération de la paire RSA
      final keyGenerator = pc.RSAKeyGenerator();
      keyGenerator.init(
        pc.ParametersWithRandom(
          pc.RSAKeyGeneratorParameters(
            BigInt.parse('65537'),
            4096,
            64,
          ),
          secureRandom,
        ),
      );
      final pc.AsymmetricKeyPair pair = keyGenerator.generateKeyPair();
      final String publicPem = RsaKeyUtils.encodePublicKeyToPem(
        pair.publicKey as pc.RSAPublicKey,
      );

      // 3. Appel au provider
      final groupProvider =
          Provider.of<GroupProvider>(context, listen: false);
      final String realGroupId = await groupProvider.createGroup(
        _groupNameController.text.trim(),
        publicPem,
      );

      // 4. Stockage de la paire pour ce groupe
      await KeyManager().storeKeyPairForGroup(realGroupId, pair);

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
    final existing = await KeyManager().getKeyPairForGroup(groupId);
    if (existing != null) {
      SnackbarService.showInfo(
        context,
        "Vous avez déjà une demande ou vous êtes membre",
      );
      setState(() => _loading = false);
      return;
    }
    try {
      final secureRandom = pc.FortunaRandom();
      secureRandom.seed(pc.KeyParameter(
        Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        ),
      ));
      final keyGenerator = pc.RSAKeyGenerator();
      keyGenerator.init(
        pc.ParametersWithRandom(
          pc.RSAKeyGeneratorParameters(
            BigInt.parse('65537'),
            4096,
            64,
          ),
          secureRandom,
        ),
      );
      final pc.AsymmetricKeyPair pair = keyGenerator.generateKeyPair();
      final String publicPem = RsaKeyUtils.encodePublicKeyToPem(
        pair.publicKey as pc.RSAPublicKey,
      );

      final groupProvider =
          Provider.of<GroupProvider>(context, listen: false);
      await groupProvider.sendJoinRequest(groupId, publicPem);

      await KeyManager().storeKeyPairForGroup(groupId, pair);

      SnackbarService.showSuccess(
          context, 'Demande d’adhésion envoyée');
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
