import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:crypto/crypto.dart';
import 'package:flutter_message_app/core/crypto/key_manager.dart';

Future<pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey>> generateRsaKeyPairTask(dynamic _) async {
  final keyGen = pc.RSAKeyGenerator()
    ..init(pc.ParametersWithRandom(
      pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 4096, 64),
      pc.SecureRandom("Fortuna")..seed(pc.KeyParameter(Uint8List.fromList(List.generate(32, (_) => 42))))
    ));
  return keyGen.generateKeyPair();
}

Future<Map<String, dynamic>> encryptMessageTask(Map<String, dynamic> params) async {
  final plaintext = params['plaintext'] as String;
  final Map<String, String> publicKeysByUserId = Map<String, String>.from(params['publicKeysByUserId']);

  final aesKey = Uint8List(32)..setAll(0, List.generate(32, (_) => 42));
  final iv = encrypt.IV.fromLength(16);
  final encrypter = encrypt.Encrypter(encrypt.AES(encrypt.Key(aesKey), mode: encrypt.AESMode.cbc));
  final encryptedText = encrypter.encrypt(plaintext, iv: iv);

  final encryptedKeys = <String, String>{};
  for (final entry in publicKeysByUserId.entries) {
    final key = parsePublicKeyFromPem(entry.value);
    final cipher = pc.OAEPEncoding(pc.RSAEngine())
      ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
    final encKey = cipher.process(aesKey);
    encryptedKeys[entry.key] = base64.encode(encKey);
  }

  return {
    "encrypted": base64.encode(encryptedText.bytes),
    "iv": base64.encode(iv.bytes),
    "keys": encryptedKeys,
  };
}

Future<String> decryptMessageTask(Map<String, dynamic> params) async {
  final encrypted = params['encrypted'] as String;
  final iv = params['iv'] as String;
  final aesKeyBytes = base64.decode(params['aesKey'] as String);

  final encrypter = encrypt.Encrypter(encrypt.AES(encrypt.Key(aesKeyBytes), mode: encrypt.AESMode.cbc));
  return encrypter.decrypt(
    encrypt.Encrypted(base64.decode(encrypted)),
    iv: encrypt.IV(base64.decode(iv)),
  );
}

Future<String> signPayloadTask(Map<String, dynamic> payload) async {
  final userKey = await KeyManager().getKeyPairForGroup('user_rsa');
  if (userKey == null) throw Exception("Pas de clé RSA utilisateur");

  final dataToSign = utf8.encode(payload['encrypted'] + payload['iv']);
  final hash = sha256.convert(dataToSign).bytes;

  final signer = pc.Signer("SHA-256/RSA")
    ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(userKey.privateKey as pc.RSAPrivateKey));
  final sig = signer.generateSignature(Uint8List.fromList(hash));
  return base64.encode((sig as pc.RSASignature).bytes);
}

Future<bool> verifySignatureTask(Map<String, dynamic> params) async {
  try {
    final payload = Map<String, dynamic>.from(params['payload']);
    final signature = params['signature'] as String;
    final senderPublicKeyPem = params['senderPublicKeyPem'] as String;

    final key = parsePublicKeyFromPem(senderPublicKeyPem);
    final data = utf8.encode(payload['encrypted'] + payload['iv']);
    final hash = sha256.convert(data).bytes;

    final verifier = pc.Signer("SHA-256/RSA")
      ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
    final sigBytes = base64.decode(signature);

    return verifier.verifySignature(Uint8List.fromList(hash), pc.RSASignature(sigBytes));
  } catch (_) {
    return false;
  }
}
