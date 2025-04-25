import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter_message_app/core/crypto/key_manager.dart';

class EncryptionUtils {
  static final _secureRandom = pc.SecureRandom("Fortuna")
    ..seed(pc.KeyParameter(Uint8List.fromList(List.generate(32, (_) => 42))));

  static Uint8List _generateRandomBytes(int length) {
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = _secureRandom.nextUint8();
    }
    return bytes;
  }

  static Future<Map<String, dynamic>> encryptMessageForUsers({
    required String groupId,
    required String plaintext,
    required Map<String, String> publicKeysByUserId,
  }) async {
    final aesKey = _generateRandomBytes(32);
    final iv = IV.fromLength(16);
    final encrypter = Encrypter(AES(Key(aesKey), mode: AESMode.cbc));
    final encryptedText = encrypter.encrypt(plaintext, iv: iv);

    final Map<String, String> encryptedKeys = {};
    for (final entry in publicKeysByUserId.entries) {
      final key = parsePublicKeyFromPem(entry.value);
      final cipher = pc.OAEPEncoding(pc.RSAEngine())
        ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
      final encKey = cipher.process(aesKey);
      encryptedKeys[entry.key] = base64.encode(encKey);
    }

    final payload = {
      "encrypted": base64.encode(encryptedText.bytes),
      "iv": base64.encode(iv.bytes),
      "keys": encryptedKeys,
    };

    // Signature facultative : signer le message
    final signature = await signPayload(payload);
    payload["signature"] = signature;
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
    final encrypter = Encrypter(AES(Key(aesKey), mode: AESMode.cbc));

    final decrypted = encrypter.decrypt(
      Encrypted(base64.decode(encrypted)),
      iv: IV(base64.decode(iv)),
    );

    return decrypted;
  }

  static Future<String> signPayload(Map<String, dynamic> payload) async {
    final userKey = await KeyManager().getKeyPairForGroup("user_rsa");
    if (userKey == null) throw Exception("Pas de clé RSA personnelle");

    final dataToSign = utf8.encode(payload["encrypted"] + payload["iv"]);
    final hash = sha256.convert(dataToSign).bytes;

    final signer = pc.Signer("SHA-256/RSA")
      ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(userKey.privateKey as pc.RSAPrivateKey));
    final sig = signer.generateSignature(Uint8List.fromList(hash));
    return base64.encode((sig as pc.RSASignature).bytes);
  }

  static Future<bool> verifySignature({
    required Map<String, dynamic> payload,
    required String signature,
    required String senderPublicKeyPem,
  }) async {
    try {
      final key = parsePublicKeyFromPem(senderPublicKeyPem);
      final data = utf8.encode(payload["encrypted"] + payload["iv"]);
      final hash = sha256.convert(data).bytes;

      final verifier = pc.Signer("SHA-256/RSA")
        ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
      final sigBytes = base64.decode(signature);

      return verifier.verifySignature(Uint8List.fromList(hash), pc.RSASignature(sigBytes));
    } catch (_) {
      return false;
    }
  }
}
