import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;

class SignatureUtils {
  static Uint8List signDataWithPrivateKey(Uint8List data, pc.RSAPrivateKey privateKey) {
    final signer = pc.Signer("SHA-256/RSA")
      ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey));
    final sig = signer.generateSignature(data) as pc.RSASignature;
    return sig.bytes;
  }

  static bool verifySignature({
    required Uint8List data,
    required Uint8List signature,
    required pc.RSAPublicKey publicKey,
  }) {
    final verifier = pc.Signer('SHA-256/RSA')
      ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(publicKey));
    return verifier.verifySignature(
      data,
      pc.RSASignature(signature),
    );
  }
} 