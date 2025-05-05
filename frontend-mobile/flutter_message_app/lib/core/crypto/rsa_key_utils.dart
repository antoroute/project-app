import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart';

class RsaKeyUtils {
  static pc.RSAPublicKey parsePublicKeyFromPem(String pem) {
    final cleanPem = pem.replaceAll(RegExp(r'-----.*?-----|\s'), '');
    final bytes = base64.decode(cleanPem);

    final parser = ASN1Parser(bytes);
    final topLevelSeq = parser.nextObject() as ASN1Sequence;

    if (topLevelSeq.elements.length != 2) {
      throw FormatException('Clé publique invalide, structure ASN.1 inattendue (topLevel)');
    }

    final algoSeq = topLevelSeq.elements[0] as ASN1Sequence;
    final oid = algoSeq.elements[0] as ASN1ObjectIdentifier;
    if (oid.identifier != '1.2.840.113549.1.1.1') {
      throw FormatException('OID inattendu : algorithme non RSA');
    }

    final publicKeyBitString = topLevelSeq.elements[1] as ASN1BitString;

    final publicKeyParser = ASN1Parser(publicKeyBitString.contentBytes());
    final publicKeySeq = publicKeyParser.nextObject() as ASN1Sequence;

    final modulus = publicKeySeq.elements[0] as ASN1Integer;
    final exponent = publicKeySeq.elements[1] as ASN1Integer;

    return pc.RSAPublicKey(modulus.valueAsBigInteger, exponent.valueAsBigInteger);
  }

  static pc.RSAPrivateKey parsePrivateKeyFromPem(String pem) {
    final lines = pem.split('\n');
    final base64Str = lines.where((l) => !l.startsWith('---')).join();
    final bytes = base64.decode(base64Str);

    final parser = ASN1Parser(bytes);
    final topLevelSeq = parser.nextObject() as ASN1Sequence;

    final modulus = (topLevelSeq.elements[1] as ASN1Integer).valueAsBigInteger;
    final publicExponent = (topLevelSeq.elements[2] as ASN1Integer).valueAsBigInteger;
    final privateExponent = (topLevelSeq.elements[3] as ASN1Integer).valueAsBigInteger;
    final p = (topLevelSeq.elements[4] as ASN1Integer).valueAsBigInteger;
    final q = (topLevelSeq.elements[5] as ASN1Integer).valueAsBigInteger;

    return pc.RSAPrivateKey(modulus, privateExponent, p, q);
  }

  static String encodePublicKeyToPem(pc.RSAPublicKey publicKey) {
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

  static String encodePrivateKeyToPem(pc.RSAPrivateKey privateKey) {
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

    return '-----BEGIN PRIVATE KEY-----\n$formatted-----END PRIVATE KEY-----';
  }

  static Uint8List encryptAESKeyWithRSAOAEP(String publicKeyPem, Uint8List aesKey) {
    final publicKey = parsePublicKeyFromPem(publicKeyPem);
    final cipher = pc.OAEPEncoding(pc.RSAEngine())
      ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(publicKey));
    return cipher.process(aesKey);
  }
} 