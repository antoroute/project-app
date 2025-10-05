import 'package:cryptography/cryptography.dart';
import 'package:flutter_message_app/core/crypto/key_manager_pointycastle.dart';

/// Adaptateur pour utiliser KeyManagerHybrid avec l'interface cryptography
class HybridAdapter {
  static final HybridAdapter instance = HybridAdapter._internal();
  HybridAdapter._internal();

  final KeyManagerHybrid _keyManager = KeyManagerHybrid.instance;

  /// Adapte KeyManagerHybrid vers SimpleKeyPair pour compatibilité
  Future<SimpleKeyPair> getEd25519KeyPair(String groupId, String deviceId) async {
    return await _keyManager.loadEd25519KeyPair(groupId, deviceId);
  }

  /// Adapte KeyManagerHybrid vers SimpleKeyPair pour compatibilité
  Future<SimpleKeyPair> getX25519KeyPair(String groupId, String deviceId) async {
    return await _keyManager.loadX25519KeyPair(groupId, deviceId);
  }

  /// Génère et stocke les clés
  Future<void> ensureKeysFor(String groupId, String deviceId) async {
    await _keyManager.ensureKeysFor(groupId, deviceId);
  }

  /// Vérifie si les clés existent
  Future<bool> hasKeys(String groupId, String deviceId) async {
    return await _keyManager.hasKeys(groupId, deviceId);
  }

  /// Retourne les clés publiques en Base64
  Future<Map<String, String>> publicKeysBase64(String groupId, String deviceId) async {
    return await _keyManager.publicKeysBase64(groupId, deviceId);
  }
}
