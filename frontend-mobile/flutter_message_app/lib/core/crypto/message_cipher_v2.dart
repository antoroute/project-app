import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_message_app/core/crypto/crypto_isolate_data.dart';
import 'package:flutter_message_app/core/crypto/crypto_isolate_service.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';
import 'package:flutter_message_app/core/crypto/message_envelope_verifier.dart';
import 'package:flutter_message_app/core/services/key_directory_service.dart';
import 'package:flutter_message_app/core/services/message_key_cache.dart';
import 'package:flutter_message_app/core/services/performance_benchmark.dart';
import 'package:uuid/uuid.dart';

class MessageCipherV2 {
  static final AesGcm _aead = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static int _taskSequence = 0;

  static Uint8List _randomBytes(int length) => Uint8List.fromList(
    List<int>.generate(length, (_) => Random.secure().nextInt(256)),
  );

  static String _b64(Uint8List bytes) => base64.encode(bytes);

  static String _cleanBase64(String input) {
    var cleaned = input.trim().replaceAll(RegExp(r'[\s\n\r]'), '');
    if (!RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(cleaned)) {
      throw const MessageAuthenticationException('invalid_encoding');
    }
    cleaned = cleaned.replaceAll('-', '+').replaceAll('_', '/');
    while (cleaned.length % 4 != 0) {
      cleaned += '=';
    }
    return cleaned;
  }

  static Future<Map<String, dynamic>> encrypt({
    required String groupId,
    required String convId,
    required String senderUserId,
    required String senderDeviceId,
    required List<GroupDeviceKeyEntry> recipientsDevices,
    required Uint8List plaintext,
  }) async {
    final messageId = const Uuid().v4();
    final sentAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final messageKey = _randomBytes(32);
    final contentNonce = _randomBytes(12);

    final contentBox = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(messageKey),
      nonce: contentNonce,
    );
    final ciphertext = Uint8List.fromList(
      contentBox.cipherText + contentBox.mac.bytes,
    );

    final x25519 = X25519();
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
    final ephemeralPublicKeyB64 = _b64(
      Uint8List.fromList(ephemeralPublicKey.bytes),
    );

    final salt = Uint8List.fromList(
      crypto.sha256
          .convert(utf8.encode('$messageId:${_b64(_randomBytes(16))}'))
          .bytes,
    );

    final recipients = <Map<String, dynamic>>[];
    for (final entry in recipientsDevices) {
      if (entry.status != 'active' || entry.pkKemB64.isEmpty) {
        continue;
      }
      final recipientPublicKey = SimplePublicKey(
        base64.decode(_cleanBase64(entry.pkKemB64)),
        type: KeyPairType.x25519,
      );
      final sharedSecret = await x25519.sharedSecretKey(
        keyPair: ephemeralKeyPair,
        remotePublicKey: recipientPublicKey,
      );
      final context =
          'project-app/v2 $groupId $convId ${entry.userId} ${entry.deviceId}';
      final wrappingKey = await _hkdf.deriveKey(
        secretKey: sharedSecret,
        nonce: salt,
        info: utf8.encode(context),
      );
      final wrapNonce = _randomBytes(12);
      final wrapBox = await _aead.encrypt(
        messageKey,
        secretKey: wrappingKey,
        nonce: wrapNonce,
      );
      recipients.add({
        'userId': entry.userId,
        'deviceId': entry.deviceId,
        'key_version': entry.keyVersion,
        'wrap': _b64(
          Uint8List.fromList(wrapBox.cipherText + wrapBox.mac.bytes),
        ),
        'nonce': _b64(wrapNonce),
      });
    }

    if (recipients.isEmpty) {
      throw Exception('Aucun appareil destinataire actif');
    }

    final senderKeyVersion = await KeyManagerFinal.instance.currentKeyVersion(
      groupId,
      senderDeviceId,
    );
    final payload = <String, dynamic>{
      'v': 2,
      'alg': {
        'kem': 'X25519',
        'kdf': 'HKDF-SHA256',
        'aead': 'AES-256-GCM',
        'sig': 'Ed25519',
      },
      'groupId': groupId,
      'convId': convId,
      'messageId': messageId,
      'sentAt': sentAt,
      'sender': {
        'userId': senderUserId,
        'deviceId': senderDeviceId,
        'eph_pub': ephemeralPublicKeyB64,
        'key_version': senderKeyVersion,
      },
      'recipients': recipients,
      'iv': _b64(contentNonce),
      'ciphertext': _b64(ciphertext),
      'salt': _b64(salt),
    };

    final signingKey = await KeyManagerFinal.instance.loadEd25519KeyPair(
      groupId,
      senderDeviceId,
      keyVersion: senderKeyVersion,
    );
    final signature = await Ed25519().sign(
      MessageEnvelopeVerifier.canonicalBytes(payload),
      keyPair: signingKey,
    );
    payload['sig'] = _b64(Uint8List.fromList(signature.bytes));
    return payload;
  }

  /// Unique chemin autorisé pour remettre du texte clair à l'application.
  /// Le contexte, l'appareil expéditeur et Ed25519 sont validés avant AES-GCM.
  static Future<Map<String, dynamic>> decryptVerified({
    required String groupId,
    required String expectedConversationId,
    required String myUserId,
    required String myDeviceId,
    required Map<String, dynamic> messageV2,
    required KeyDirectoryService keyDirectory,
    int priority = 0,
  }) async {
    return PerformanceBenchmark.instance.measureAsync(
      'message_receive_verified_total',
      () async {
        try {
          final verifiedEnvelope =
              await MessageEnvelopeVerifier.verifyUsingDirectory(
                expectedGroupId: groupId,
                expectedConversationId: expectedConversationId,
                recipientUserId: myUserId,
                recipientDeviceId: myDeviceId,
                messageV2: messageV2,
                keyDirectory: keyDirectory,
                priority: priority,
              );

          final cachedKey = await MessageKeyCache.instance
              .getVerifiedMessageKey(verifiedEnvelope);
          if (cachedKey != null) {
            final clear = await PerformanceBenchmark.instance.measureAsync(
              'message_decrypt_verified_cached',
              () => _decryptContent(messageV2, cachedKey),
            );
            return {'decryptedText': clear, 'signatureValid': true};
          }

          final sender = Map<String, dynamic>.from(messageV2['sender'] as Map);
          final recipients = messageV2['recipients'] as List<dynamic>;
          final recipient = recipients
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .singleWhere(
                (entry) =>
                    entry['userId'] == myUserId &&
                    entry['deviceId'] == myDeviceId,
              );

          final privateKey = await KeyManagerFinal.instance
              .getX25519PrivateKeyBytes(
                groupId,
                myDeviceId,
                keyVersion: _recipientKeyVersion(recipient),
              );
          final task = DecryptPipelineTask(
            taskId: _nextTaskId('decrypt'),
            priority: priority,
            myPrivateKeyBytes: privateKey,
            remotePublicKeyBytes: base64.decode(
              _cleanBase64(sender['eph_pub'] as String),
            ),
            groupId: groupId,
            convId: expectedConversationId,
            myUserId: myUserId,
            myDeviceId: myDeviceId,
            salt: base64.decode(_cleanBase64(messageV2['salt'] as String)),
            wrapBytes: base64.decode(_cleanBase64(recipient['wrap'] as String)),
            wrapNonce: base64.decode(
              _cleanBase64(recipient['nonce'] as String),
            ),
            iv: base64.decode(_cleanBase64(messageV2['iv'] as String)),
            ciphertext: base64.decode(
              _cleanBase64(messageV2['ciphertext'] as String),
            ),
          );

          final result = await PerformanceBenchmark.instance.measureAsync(
            'message_decrypt_verified_pipeline',
            () => CryptoIsolateService.instance.executeDecryptPipeline(task),
          );
          final clear = result.decryptedTextBytes;
          final messageKey = result.messageKeyBytes;
          if (result.error != null ||
              clear == null ||
              messageKey == null ||
              messageKey.length != 32) {
            throw const MessageAuthenticationException('decryption_failed');
          }

          await MessageKeyCache.instance.cacheVerifiedMessageKey(
            envelope: verifiedEnvelope,
            messageKey: messageKey,
          );
          return {'decryptedText': clear, 'signatureValid': true};
        } on MessageAuthenticationException {
          rethrow;
        } catch (_) {
          throw const MessageAuthenticationException('decryption_failed');
        }
      },
    );
  }

  static int _recipientKeyVersion(Map<String, dynamic> recipient) {
    final value = recipient['key_version'];
    if (value is int && value >= 1) return value;
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null && parsed >= 1) return parsed;
    }
    throw const MessageAuthenticationException('invalid_key_version');
  }

  /// Alias historique. Malgré son nom, il ne saute plus la signature.
  static Future<Map<String, dynamic>> decryptFast({
    required String groupId,
    required String expectedConversationId,
    required String myUserId,
    required String myDeviceId,
    required Map<String, dynamic> messageV2,
    required KeyDirectoryService keyDirectory,
    int priority = 0,
  }) => decryptVerified(
    groupId: groupId,
    expectedConversationId: expectedConversationId,
    myUserId: myUserId,
    myDeviceId: myDeviceId,
    messageV2: messageV2,
    keyDirectory: keyDirectory,
    priority: priority,
  );

  static Future<Map<String, dynamic>> decrypt({
    required String groupId,
    required String expectedConversationId,
    required String myUserId,
    required String myDeviceId,
    required Map<String, dynamic> messageV2,
    required KeyDirectoryService keyDirectory,
  }) => decryptVerified(
    groupId: groupId,
    expectedConversationId: expectedConversationId,
    myUserId: myUserId,
    myDeviceId: myDeviceId,
    messageV2: messageV2,
    keyDirectory: keyDirectory,
  );

  static Future<Uint8List> _decryptContent(
    Map<String, dynamic> messageV2,
    Uint8List messageKey,
  ) async {
    final iv = base64.decode(_cleanBase64(messageV2['iv'] as String));
    final ciphertext = base64.decode(
      _cleanBase64(messageV2['ciphertext'] as String),
    );
    if (iv.length != 12 || ciphertext.length < 16) {
      throw const MessageAuthenticationException('invalid_ciphertext');
    }
    final cipherLength = ciphertext.length - 16;
    final box = SecretBox(
      ciphertext.sublist(0, cipherLength),
      nonce: iv,
      mac: Mac(ciphertext.sublist(cipherLength)),
    );
    try {
      final clear = await _aead.decrypt(box, secretKey: SecretKey(messageKey));
      return Uint8List.fromList(clear);
    } catch (_) {
      throw const MessageAuthenticationException('invalid_ciphertext');
    }
  }

  static String _nextTaskId(String operation) =>
      '$operation-${DateTime.now().microsecondsSinceEpoch}-${_taskSequence++}';
}
