import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_message_app/core/crypto/crypto_tasks.dart';
import 'package:flutter_message_app/core/crypto/key_manager.dart';
import 'package:pointycastle/export.dart' as pc;

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
      payload['senderPublicKey'] = encodePublicKeyToPem(keyPair.publicKey as pc.RSAPublicKey);
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

  static Future<bool> verifySignature({
    required Map<String, dynamic> payload,
    required String signature,
    required String senderPublicKeyPem,
  }) async {
    return compute(verifySignatureTask, {
      'payload': payload,
      'signature': signature,
      'senderPublicKeyPem': senderPublicKeyPem,
    });
  }

  static Uint8List generateRandomAESKey() {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  static Uint8List encryptAESKeyWithRSAOAEP(String publicKeyPem, Uint8List aesKey) {
    final publicKey = parsePublicKeyFromPem(publicKeyPem);

    final cipher = pc.OAEPEncoding(pc.RSAEngine())
      ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(publicKey));

    return cipher.process(aesKey);
  }

  static Uint8List signDataWithPrivateKey(Uint8List data, pc.RSAPrivateKey privateKey) {
    final signer = pc.Signer("SHA-256/RSA")
      ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey));
    final sig = signer.generateSignature(data) as pc.RSASignature;
    return sig.bytes;
  }

  static Future<String> decryptMessageTaskSimple(Map<String, dynamic> params) async {
    return compute(decryptMessageTask, params);
  }

  static Future<Map<String, dynamic>> encryptMessageTaskSimple(Map<String, dynamic> params) async {
    return compute(encryptMessageTask, params);
  }

}