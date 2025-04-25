import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart';

class KeyManager {
  static final _instance = KeyManager._internal();
  final _storage = const FlutterSecureStorage();

  factory KeyManager() => _instance;
  KeyManager._internal();

  Future<void> generateKeyPairForGroup(String groupId) async {
    final keyGen = pc.RSAKeyGenerator()
      ..init(pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 4096, 64),
        pc.SecureRandom("Fortuna")
          ..seed(pc.KeyParameter(Uint8List.fromList(List.generate(32, (_) => 42)))),
      ));

    final pair = keyGen.generateKeyPair();
    final publicPem = _encodePublicKeyToPem(pair.publicKey as pc.RSAPublicKey);
    final privatePem = _encodePrivateKeyToPem(pair.privateKey as pc.RSAPrivateKey);

    await _storage.write(
      key: "rsa_keypair_$groupId",
      value: jsonEncode({"public": publicPem, "private": privatePem}),
    );
  }

  Future<pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey>?> getKeyPairForGroup(String groupId) async {
    final jsonStr = await _storage.read(key: "rsa_keypair_$groupId");
    if (jsonStr == null) return null;
    final data = jsonDecode(jsonStr);
    return pc.AsymmetricKeyPair(
      _parsePublicKeyFromPem(data['public']),
      _parsePrivateKeyFromPem(data['private']),
    );
  }

  Future<void> deleteKeyPair(String groupId) async {
    await _storage.delete(key: "rsa_keypair_$groupId");
  }

  String _encodePublicKeyToPem(pc.RSAPublicKey publicKey) {
    final algorithmSeq = ASN1Sequence()
      ..add(ASN1ObjectIdentifier(Uint8List.fromList([1, 2, 840, 113549, 1, 1, 1])))
      ..add(ASN1Null());
    final publicKeySeq = ASN1Sequence()
      ..add(ASN1Integer(publicKey.modulus!))
      ..add(ASN1Integer(publicKey.exponent!));
    final publicKeyBitString = ASN1BitString(Uint8List.fromList(publicKeySeq.encodedBytes));
    final topLevelSeq = ASN1Sequence()
      ..add(algorithmSeq)
      ..add(publicKeyBitString);
    return "-----BEGIN PUBLIC KEY-----\n" +
        base64.encode(topLevelSeq.encodedBytes).replaceAllMapped(RegExp(r".{1,64}"), (match) => "${match.group(0)}\n") +
        "-----END PUBLIC KEY-----";
  }

  String _encodePrivateKeyToPem(pc.RSAPrivateKey privateKey) {
    final topLevelSeq = ASN1Sequence()
      ..add(ASN1Integer(BigInt.from(0)))
      ..add(ASN1Integer(privateKey.n!))
      ..add(ASN1Integer(privateKey.publicExponent!))
      ..add(ASN1Integer(privateKey.exponent!))
      ..add(ASN1Integer(privateKey.p!))
      ..add(ASN1Integer(privateKey.q!))
      ..add(ASN1Integer(privateKey.exponent! % (privateKey.p! - BigInt.one)))
      ..add(ASN1Integer(privateKey.exponent! % (privateKey.q! - BigInt.one)))
      ..add(ASN1Integer(privateKey.q!.modInverse(privateKey.p!)));
    return "-----BEGIN PRIVATE KEY-----\n" +
        base64.encode(topLevelSeq.encodedBytes).replaceAllMapped(RegExp(r".{1,64}"), (match) => "${match.group(0)}\n") +
        "-----END PRIVATE KEY-----";
  }

  pc.RSAPublicKey _parsePublicKeyFromPem(String pem) {
    final bytes = base64.decode(pem.split('\n').where((l) => !l.startsWith('---')).join());
    final parser = ASN1Parser(bytes);
    final topLevelSeq = parser.nextObject() as ASN1Sequence;
    final publicKeyBitString = topLevelSeq.elements![1] as ASN1BitString;
    final publicKeyAsn = ASN1Parser(publicKeyBitString.valueBytes!());
    final publicKeySeq = publicKeyAsn.nextObject() as ASN1Sequence;
    final modulus = publicKeySeq.elements![0] as ASN1Integer;
    final exponent = publicKeySeq.elements![1] as ASN1Integer;
    return pc.RSAPublicKey(modulus.valueAsBigInteger!, exponent.valueAsBigInteger!);
  }

  pc.RSAPrivateKey _parsePrivateKeyFromPem(String pem) {
    final bytes = base64.decode(pem.split('\n').where((l) => !l.startsWith('---')).join());
    final parser = ASN1Parser(bytes);
    final seq = parser.nextObject() as ASN1Sequence;
    final modulus = seq.elements![1] as ASN1Integer;
    final publicExp = seq.elements![2] as ASN1Integer;
    final privateExp = seq.elements![3] as ASN1Integer;
    final p = seq.elements![4] as ASN1Integer;
    final q = seq.elements![5] as ASN1Integer;
    return pc.RSAPrivateKey(modulus.valueAsBigInteger!, privateExp.valueAsBigInteger!, p.valueAsBigInteger!, q.valueAsBigInteger!);
  }

}

pc.RSAPublicKey parsePublicKeyFromPem(String pem) {
  return KeyManager()._parsePublicKeyFromPem(pem);
}

String encodePublicKeyToPem(pc.RSAPublicKey key) {
  return KeyManager()._encodePublicKeyToPem(key);
}
