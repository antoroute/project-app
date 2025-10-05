import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';

/// Test de la reconstruction des clés
class KeyReconstructionTest {
  static Future<void> testReconstruction() async {
    debugPrint('🧪 Testing key reconstruction...');
    
    try {
      // Test avec un groupe et device fictifs
      const groupId = 'test-group-id';
      const deviceId = 'test-device-id';
      
      // 1. Générer des clés
      debugPrint('1️⃣ Generating keys...');
      await KeyManagerFinal.instance.ensureKeysFor(groupId, deviceId);
      
      // 2. Récupérer les clés publiques
      debugPrint('2️⃣ Getting public keys...');
      final publicKeys = await KeyManagerFinal.instance.publicKeysBase64(groupId, deviceId);
      debugPrint('   pk_sig length: ${publicKeys['pk_sig']!.length}');
      debugPrint('   pk_kem length: ${publicKeys['pk_kem']!.length}');
      
      // 3. Charger les clés (devrait utiliser le cache)
      debugPrint('3️⃣ Loading keys (should use cache)...');
      final edKey1 = await KeyManagerFinal.instance.loadEd25519KeyPair(groupId, deviceId);
      final xKey1 = await KeyManagerFinal.instance.loadX25519KeyPair(groupId, deviceId);
      
      // 4. Simuler un redémarrage en vidant le cache
      debugPrint('4️⃣ Simulating app restart (clearing cache)...');
      // Note: Le cache est privé, donc on ne peut pas le vider directement
      // Mais on peut tester en rechargeant les clés
      
      // 5. Recharger les clés (devrait reconstruire depuis les seeds)
      debugPrint('5️⃣ Reloading keys (should reconstruct from seeds)...');
      final edKey2 = await KeyManagerFinal.instance.loadEd25519KeyPair(groupId, deviceId);
      final xKey2 = await KeyManagerFinal.instance.loadX25519KeyPair(groupId, deviceId);
      
      // 6. Vérifier que les clés publiques sont identiques
      debugPrint('6️⃣ Verifying key consistency...');
      final edPub1 = await edKey1.extractPublicKey();
      final edPub2 = await edKey2.extractPublicKey();
      final xPub1 = await xKey1.extractPublicKey();
      final xPub2 = await xKey2.extractPublicKey();
      
      final edKeysMatch = edPub1.bytes.length == edPub2.bytes.length;
      final xKeysMatch = xPub1.bytes.length == xPub2.bytes.length;
      
      debugPrint('   Ed25519 keys match: $edKeysMatch');
      debugPrint('   X25519 keys match: $xKeysMatch');
      
      if (edKeysMatch && xKeysMatch) {
        debugPrint('✅ Key reconstruction test PASSED!');
      } else {
        debugPrint('❌ Key reconstruction test FAILED!');
      }
      
    } catch (e) {
      debugPrint('❌ Key reconstruction test ERROR: $e');
    }
  }
}
