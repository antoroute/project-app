import 'dart:convert';
import 'dart:math';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart';
import 'package:flutter_message_app/core/crypto/crypto_tasks.dart';
import 'package:flutter_message_app/core/crypto/key_manager.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:flutter_message_app/core/crypto/rsa_key_utils.dart';
import 'package:flutter_message_app/core/crypto/aes_utils.dart';
import 'package:flutter_message_app/core/crypto/signature_utils.dart';

class EncryptionUtils {
  static Future<Map<String, dynamic>> encryptMessageForUsers({
    required String groupId,
    required String plaintext,
    required Map<String, String> publicKeysByUserId,
  }) async {
    final payload = await compute(encryptMessageTask, {
      'plaintext': plaintext,
      'publicKeysByUserId': publicKeysByUserId,
    });

    final signature = await compute(signPayloadTask, payload);
    payload['signature'] = signature;

    final keyPair = await KeyManager().getKeyPairForGroup('user_rsa');
    if (keyPair != null) {
      payload['senderPublicKey'] = RsaKeyUtils.encodePublicKeyToPem(keyPair.publicKey as pc.RSAPublicKey);
    }
    return payload;
  }

  static Future<String> decryptMessageFromPayload({
    required String groupId,
    required String encrypted,
    required String iv,
    required String encryptedKeyForCurrentUser,
  }) async {
    final keyPair = await KeyManager().getKeyPairForGroup(groupId);
    if (keyPair == null) throw Exception('RSA key pair manquante pour ce groupe');

    final privateKey = keyPair.privateKey as pc.RSAPrivateKey;
    final cipher = pc.OAEPEncoding(pc.RSAEngine())
      ..init(false, pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey));

    final aesKey = cipher.process(base64.decode(encryptedKeyForCurrentUser));
    return compute(decryptMessageTask, {
      'encrypted': encrypted,
      'iv': iv,
      'aesKey': base64.encode(aesKey),
    });
  }

  static Future<String> signPayload(Map<String, dynamic> payload) async {
    return compute(signPayloadTask, payload);
  }

  static String canonicalJson(Map<String, dynamic> map) {
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );

    final buffer = StringBuffer('{');
    bool first = true;
    for (var entry in sorted.entries) {
      if (!first) buffer.write(',');
      buffer.write('"${entry.key}":"${entry.value}"');
      first = false;
    }
    buffer.write('}');
    return buffer.toString();
  }

  static Future<bool> verifySignature({
    required Map<String, dynamic> payload,
    required String signature,
    required String senderPublicKeyPem,
  }) async {
    try {
      print('🔍 Début vérification signature...');
      final canonical = canonicalJson(payload);
      final publicKey = RsaKeyUtils.parsePublicKeyFromPem(senderPublicKeyPem);
      final sig = base64.decode(signature);

      final verifier = pc.Signer('SHA-256/RSA')
        ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(publicKey));

      final verified = verifier.verifySignature(
        Uint8List.fromList(utf8.encode(canonical)),
        pc.RSASignature(sig),
      );

      print(verified ? '✅ Signature valide (interne)' : '⚠️ Signature invalide (interne)');
      return verified;
    } catch (e, st) {
      print('❌ Exception pendant la vérification de signature : $e');
      print(st);
      return false;
    }
  }

  static Future<String> decryptMessageTaskSimple(Map<String, dynamic> params) async {
    return compute(decryptMessageTask, params);
  }

  static Future<Map<String, dynamic>> encryptMessageTaskSimple(Map<String, dynamic> params) async {
    return compute(encryptMessageTask, params);
  }

  static Future<Map<String, String>> encryptWithAESKey({
    required String plaintext,
    required Uint8List aesKey,
  }) async {
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(aesKey), mode: encrypt.AESMode.cbc),
    );
    final encrypted = encrypter.encrypt(plaintext, iv: iv);

    return {
      'encrypted': base64.encode(encrypted.bytes),
      'iv': base64.encode(iv.bytes),
    };
  }

  static decryptWithBiometricKey(String encrypted) {}

}