import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as encrypt;

class AesUtils {
  static Uint8List generateRandomAESKey({int length = 32}) {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
  }

  static Map<String, String> encryptWithAESKey({
    required String plaintext,
    required Uint8List aesKey,
  }) {
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

  static String decryptWithAESKey({
    required String encrypted,
    required String iv,
    required Uint8List aesKey,
  }) {
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(aesKey), mode: encrypt.AESMode.cbc),
    );
    return encrypter.decrypt(
      encrypt.Encrypted(base64.decode(encrypted)),
      iv: encrypt.IV(base64.decode(iv)),
    );
  }
} 