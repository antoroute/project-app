import 'dart:isolate';
import 'dart:typed_data';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';

/// Tâche de déchiffrement à envoyer à l'Isolate
class DecryptTask {
  final String messageId;
  final Uint8List cipherText;
  final Uint8List iv;
  final Uint8List aesKey; // clé AES déjà déballée
  final String algorithm; // 'AES-256-GCM'
  
  const DecryptTask({
    required this.messageId,
    required this.cipherText,
    required this.iv,
    required this.aesKey,
    required this.algorithm,
  });
}

/// Résultat de déchiffrement retourné par l'Isolate
class DecryptResult {
  final String messageId;
  final String? plaintext;
  final Object? error;
  
  const DecryptResult(this.messageId, this.plaintext, [this.error]);
}

/// Worker Isolate pour le déchiffrement en arrière-plan
void _worker(SendPort mainSendPort) async {
  final port = ReceivePort();
  mainSendPort.send(port.sendPort);

  await for (final msg in port) {
    if (msg is Map && msg['type'] == 'decrypt') {
      final String messageId = msg['messageId'] as String;
      final Uint8List cipher = msg['cipher'] as Uint8List;
      final Uint8List iv = msg['iv'] as Uint8List;
      final Uint8List aesKey = msg['key'] as Uint8List;
      // final String algorithm = msg['algorithm'] as String; // Pas utilisé pour l'instant

      try {
        // Déchiffrement AES-GCM avec cryptography
        final secretKey = SecretKey(aesKey);
        final algorithmImpl = AesGcm.with256bits();
        
        // Pour AES-GCM, le MAC est inclus dans le ciphertext
        final macLength = 16; // 128 bits pour AES-GCM
        final actualCipher = cipher.sublist(0, cipher.length - macLength);
        final mac = cipher.sublist(cipher.length - macLength);
        
        final secretBox = SecretBox(
          actualCipher,
          nonce: iv,
          mac: Mac(mac),
        );
        
        final decryptedBytes = await algorithmImpl.decrypt(
          secretBox,
          secretKey: secretKey,
        );
        
        final plaintext = utf8.decode(decryptedBytes);
        mainSendPort.send(DecryptResult(messageId, plaintext));
      } catch (e) {
        mainSendPort.send(DecryptResult(messageId, null, e));
      }
    } else if (msg is String && msg == 'dispose') {
      break;
    }
  }
}

/// Service de déchiffrement en arrière-plan avec Isolate
class DecryptionWorker {
  Isolate? _isolate;
  SendPort? _sendPort;
  final _resultPort = ReceivePort();

  /// Démarre l'Isolate si nécessaire
  Future<void> ensureStarted() async {
    if (_isolate != null && _sendPort != null) return;
    
    _isolate = await Isolate.spawn(_worker, _resultPort.sendPort);
    // Premier message reçu = SendPort du worker
    _sendPort = await _resultPort.first as SendPort;
  }

  /// Stream des résultats de déchiffrement
  Stream<DecryptResult> get resultStream async* {
    await ensureStarted();
    yield* _resultPort.cast<DecryptResult>();
  }

  /// Lance une tâche de déchiffrement
  Future<void> decrypt(String messageId, Uint8List key, Uint8List iv, Uint8List cipher, String algorithm) async {
    await ensureStarted();
    _sendPort!.send({
      'type': 'decrypt',
      'messageId': messageId,
      'key': key,
      'iv': iv,
      'cipher': cipher,
      'algorithm': algorithm,
    });
  }

  /// Libère les ressources
  Future<void> dispose() async {
    if (_sendPort != null) {
      _sendPort!.send('dispose');
      _sendPort = null;
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}
