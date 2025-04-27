import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter_message_app/core/crypto/key_manager.dart';
import 'package:flutter_message_app/core/crypto/crypto_tasks.dart'; 

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

    return payload;
  }

  static Future<String> decryptMessageFromPayload({
    required String groupId,
    required String encrypted,
    required String iv,
    required String encryptedKeyForCurrentUser,
  }) async {
    final keyPair = await KeyManager().getKeyPairForGroup(groupId);
    if (keyPair == null) throw Exception('RSA key pair introuvable pour ce groupe');

    final cipher = pc.OAEPEncoding(pc.RSAEngine())
      ..init(false, pc.PrivateKeyParameter<pc.RSAPrivateKey>(keyPair.privateKey as pc.RSAPrivateKey));

    final aesKey = cipher.process(base64.decode(encryptedKeyForCurrentUser));

    final decrypted = await compute(decryptMessageTask, {
      'encrypted': encrypted,
      'iv': iv,
      'aesKey': base64.encode(aesKey),
    });

    return decrypted;
  }

  static Future<String> signPayload(Map<String, dynamic> payload) async {
    return await compute(signPayloadTask, payload);
  }

  static Future<bool> verifySignature({
    required Map<String, dynamic> payload,
    required String signature,
    required String senderPublicKeyPem,
  }) async {
    return await compute(verifySignatureTask, {
      'payload': payload,
      'signature': signature,
      'senderPublicKeyPem': senderPublicKeyPem,
    });
  }
}
