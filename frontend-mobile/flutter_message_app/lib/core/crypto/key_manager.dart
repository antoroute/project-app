import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart';
import 'crypto_tasks.dart';
import 'package:flutter_message_app/core/crypto/rsa_key_utils.dart';

class KeyManager {
  static final KeyManager _instance = KeyManager._internal();
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  factory KeyManager() => _instance;
  KeyManager._internal();

  static const int chunkSize = 1024; // Pour Android limitations

  Future<void> generateUserKeyIfAbsent() async {
    final exists = await userKeysExist();
    if (!exists) {
      _log('🔑 Pas de clé existante, génération de user_rsa...');
      await generateKeyPairForGroup('user_rsa');
    } else {
      _log('✅ Clé user_rsa déjà existante, aucune génération nécessaire.');
    }
  }

  Future<bool> userKeysExist() async {
    final pubMeta = await _storage.read(key: "rsa_keypair_user_rsa_public-meta");
    final privMeta = await _storage.read(key: "rsa_keypair_user_rsa_private-meta");

    _log("🔎 Vérification existence clés:");
    _log("    - Public meta: ${pubMeta != null}");
    _log("    - Private meta: ${privMeta != null}");

    return pubMeta != null && privMeta != null;
  }

  Future<void> generateKeyPairForGroup(String groupId) async {
    final pair = await compute(generateRsaKeyPairTask, null);
    await storeKeyPairForGroup(groupId, pair);
  }

  Future<void> storeKeyPairForGroup(String groupId, pc.AsymmetricKeyPair keyPair) async {
    final publicPem = RsaKeyUtils.encodePublicKeyToPem(keyPair.publicKey as pc.RSAPublicKey);
    final privatePem = RsaKeyUtils.encodePrivateKeyToPem(keyPair.privateKey as pc.RSAPrivateKey);

    await _saveSplitted("rsa_keypair_${groupId}_public", publicPem);
    await _saveSplitted("rsa_keypair_${groupId}_private", privatePem);

    _log('💾 Clé pour "$groupId" sauvegardée correctement (splittée).');
  }

  Future<pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey>?> getKeyPairForGroup(String groupId) async {
    try {
      final publicPem = await _readSplitted("rsa_keypair_${groupId}_public");
      final privatePem = await _readSplitted("rsa_keypair_${groupId}_private");

      if (publicPem == null || privatePem == null) {
        _log('❌ Impossible de lire les morceaux pour "$groupId". (null détecté)');
        return null;
      }

      _log('📜 Lecture clé "$groupId" réussie, parsing ASN1...');
      final pub = RsaKeyUtils.parsePublicKeyFromPem(publicPem);
      final priv = RsaKeyUtils.parsePrivateKeyFromPem(privatePem);

      return pc.AsymmetricKeyPair(pub, priv);
    } catch (e) {
      _log('❌ Erreur parsing clé "$groupId": $e');
      return null;
    }
  }

  Future<void> deleteKeyPair(String groupId) async {
    await _deleteSplitted("rsa_keypair_${groupId}_public");
    await _deleteSplitted("rsa_keypair_${groupId}_private");
    _log('🗑️ Clé "$groupId" supprimée.');
  }

  Future<void> _saveSplitted(String baseKey, String data) async {
    final parts = <String>[];
    for (var i = 0; i < data.length; i += chunkSize) {
      parts.add(data.substring(i, (i + chunkSize > data.length) ? data.length : i + chunkSize));
    }

    for (var i = 0; i < parts.length; i++) {
      await _storage.write(key: "$baseKey-part$i", value: parts[i]);
    }
    await _storage.write(key: "$baseKey-meta", value: parts.length.toString());
  }

  Future<String?> _readSplitted(String baseKey) async {
    final meta = await _storage.read(key: "$baseKey-meta");
    if (meta == null) return null;
    final partCount = int.tryParse(meta);
    if (partCount == null) return null;

    final parts = <String>[];
    for (var i = 0; i < partCount; i++) {
      final part = await _storage.read(key: "$baseKey-part$i");
      if (part == null) return null;
      parts.add(part);
    }

    return parts.join();
  }

  Future<void> _deleteSplitted(String baseKey) async {
    final meta = await _storage.read(key: "$baseKey-meta");
    if (meta == null) return;
    final partCount = int.tryParse(meta);
    if (partCount == null) return;

    for (var i = 0; i < partCount; i++) {
      await _storage.delete(key: "$baseKey-part$i");
    }
    await _storage.delete(key: "$baseKey-meta");
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[KeyManager] $message');
    }
  }
}

// --- Export public helpers ---

String encodePublicKeyToPem(pc.RSAPublicKey publicKey) => RsaKeyUtils.encodePublicKeyToPem(publicKey);
pc.RSAPublicKey parsePublicKeyFromPem(String pem) => RsaKeyUtils.parsePublicKeyFromPem(pem);
String encodePrivateKeyToPem(pc.RSAPrivateKey privateKey) => RsaKeyUtils.encodePrivateKeyToPem(privateKey);
pc.RSAPrivateKey parsePrivateKeyFromPem(String pem) => RsaKeyUtils.parsePrivateKeyFromPem(pem);