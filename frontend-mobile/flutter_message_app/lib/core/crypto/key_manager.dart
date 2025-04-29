import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart';
import 'crypto_tasks.dart';

class KeyManager {
  static final KeyManager _instance = KeyManager._internal();
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    //iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device_only),
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
    final publicPem = _encodePublicKeyToPem(keyPair.publicKey as pc.RSAPublicKey);
    final privatePem = _encodePrivateKeyToPem(keyPair.privateKey as pc.RSAPrivateKey);

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
      final pub = _parsePublicKeyFromPem(publicPem);
      final priv = _parsePrivateKeyFromPem(privatePem);

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

  pc.RSAPublicKey _parsePublicKeyFromPem(String pem) {
    final cleanPem = pem.replaceAll(RegExp(r'-----.*?-----|\s'), '');
    final bytes = base64.decode(cleanPem);

    final parser = ASN1Parser(bytes);
    final topLevelSeq = parser.nextObject() as ASN1Sequence;

    if (topLevelSeq.elements == null || topLevelSeq.elements!.length != 2) {
      throw FormatException('Clé publique invalide, structure ASN.1 inattendue (topLevel)');
    }

    final algoSeq = topLevelSeq.elements![0] as ASN1Sequence;
    final oid = algoSeq.elements![0] as ASN1ObjectIdentifier;
    if (oid.identifier != '1.2.840.113549.1.1.1') {
      throw FormatException('OID inattendu : algorithme non RSA');
    }

    final publicKeyBitString = topLevelSeq.elements![1] as ASN1BitString;

    final publicKeyParser = ASN1Parser(publicKeyBitString.contentBytes()!);
    final publicKeySeq = publicKeyParser.nextObject() as ASN1Sequence;

    final modulus = publicKeySeq.elements![0] as ASN1Integer;
    final exponent = publicKeySeq.elements![1] as ASN1Integer;

    return pc.RSAPublicKey(modulus.valueAsBigInteger!, exponent.valueAsBigInteger!);
  }

  pc.RSAPrivateKey _parsePrivateKeyFromPem(String pem) {
    final lines = pem.split('\n');
    final base64Str = lines.where((l) => !l.startsWith('---')).join();
    final bytes = base64.decode(base64Str);

    final parser = ASN1Parser(bytes);
    final topLevelSeq = parser.nextObject() as ASN1Sequence;

    final modulus = (topLevelSeq.elements![1] as ASN1Integer).valueAsBigInteger!;
    final publicExponent = (topLevelSeq.elements![2] as ASN1Integer).valueAsBigInteger!;
    final privateExponent = (topLevelSeq.elements![3] as ASN1Integer).valueAsBigInteger!;
    final p = (topLevelSeq.elements![4] as ASN1Integer).valueAsBigInteger!;
    final q = (topLevelSeq.elements![5] as ASN1Integer).valueAsBigInteger!;

    return pc.RSAPrivateKey(modulus, privateExponent, p, q);
  }

  String _encodePublicKeyToPem(pc.RSAPublicKey publicKey) {
    final publicKeySeq = ASN1Sequence()
      ..add(ASN1Integer(publicKey.modulus!))
      ..add(ASN1Integer(publicKey.exponent!));

    final publicKeyBitString = ASN1BitString(Uint8List.fromList(publicKeySeq.encodedBytes));

    final algorithmSeq = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponents([1, 2, 840, 113549, 1, 1, 1]))
      ..add(ASN1Null());

    final topLevelSeq = ASN1Sequence()
      ..add(algorithmSeq)
      ..add(publicKeyBitString);

    final base64Str = base64.encode(topLevelSeq.encodedBytes);
    final formatted = base64Str.replaceAllMapped(RegExp('.{1,64}'), (match) => '${match.group(0)}\n');

    return '-----BEGIN PUBLIC KEY-----\n$formatted-----END PUBLIC KEY-----';
  }

  String _encodePrivateKeyToPem(pc.RSAPrivateKey privateKey) {
    final topLevelSeq = ASN1Sequence()
      ..add(ASN1Integer(BigInt.zero))
      ..add(ASN1Integer(privateKey.n!))
      ..add(ASN1Integer(privateKey.publicExponent!))
      ..add(ASN1Integer(privateKey.exponent!))
      ..add(ASN1Integer(privateKey.p!))
      ..add(ASN1Integer(privateKey.q!))
      ..add(ASN1Integer(privateKey.exponent! % (privateKey.p! - BigInt.one)))
      ..add(ASN1Integer(privateKey.exponent! % (privateKey.q! - BigInt.one)))
      ..add(ASN1Integer(privateKey.q!.modInverse(privateKey.p!)));

    final base64Str = base64.encode(topLevelSeq.encodedBytes);
    final formatted = base64Str.replaceAllMapped(RegExp('.{1,64}'), (match) => '${match.group(0)}\n');

    return '-----BEGIN RSA PRIVATE KEY-----\n$formatted-----END RSA PRIVATE KEY-----';
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[KeyManager] $message');
    }
  }
}

// --- Export public helpers ---

String encodePublicKeyToPem(pc.RSAPublicKey publicKey) => KeyManager()._encodePublicKeyToPem(publicKey);
pc.RSAPublicKey parsePublicKeyFromPem(String pem) => KeyManager()._parsePublicKeyFromPem(pem);

String encodePrivateKeyToPem(pc.RSAPrivateKey privateKey) => KeyManager()._encodePrivateKeyToPem(privateKey);
pc.RSAPrivateKey parsePrivateKeyFromPem(String pem) => KeyManager()._parsePrivateKeyFromPem(pem);