import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_message_app/core/crypto/crypto_isolate_data.dart';
import 'package:flutter_message_app/core/crypto/crypto_isolate_service.dart';
import 'package:flutter_message_app/core/services/key_directory_service.dart';
import 'package:flutter_message_app/core/services/performance_benchmark.dart';

/// Erreur sûre à exposer aux couches applicatives. Elle ne contient jamais
/// l'enveloppe, une clé ou le texte clair.
class MessageAuthenticationException implements Exception {
  const MessageAuthenticationException(this.code);

  final String code;

  @override
  String toString() => 'Message authentication failed ($code)';
}

/// Preuve typée qu'une enveloppe a passé les contrôles de contexte et Ed25519.
/// Le constructeur privé empêche le cache de recevoir accidentellement une
/// enveloppe brute.
class VerifiedMessageEnvelope {
  const VerifiedMessageEnvelope._({
    required this.messageId,
    required this.groupId,
    required this.conversationId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.recipientUserId,
    required this.recipientDeviceId,
  });

  final String messageId;
  final String groupId;
  final String conversationId;
  final String senderUserId;
  final String senderDeviceId;
  final String recipientUserId;
  final String recipientDeviceId;
}

class MessageEnvelopeVerifier {
  static int _taskSequence = 0;

  static const Map<String, String> _algorithms = {
    'kem': 'X25519',
    'kdf': 'HKDF-SHA256',
    'aead': 'AES-256-GCM',
    'sig': 'Ed25519',
  };

  static Future<VerifiedMessageEnvelope> verifyUsingDirectory({
    required String expectedGroupId,
    required String expectedConversationId,
    required String recipientUserId,
    required String recipientDeviceId,
    required Map<String, dynamic> messageV2,
    required KeyDirectoryService keyDirectory,
    int priority = 0,
  }) async {
    final sender = _sender(messageV2);
    final senderUserId = _requiredString(sender, 'userId');
    final senderDeviceId = _requiredString(sender, 'deviceId');
    final senderKeyVersion = _positiveInteger(sender['key_version']);
    final entries = await keyDirectory.getGroupDevices(expectedGroupId);

    GroupDeviceKeyEntry? senderKey;
    for (final entry in entries) {
      if (entry.userId == senderUserId &&
          entry.deviceId == senderDeviceId &&
          entry.keyVersion == senderKeyVersion) {
        senderKey = entry;
        break;
      }
    }
    if (senderKey == null) {
      throw const MessageAuthenticationException('sender_key_unavailable');
    }

    return verifyWithSenderKey(
      expectedGroupId: expectedGroupId,
      expectedConversationId: expectedConversationId,
      recipientUserId: recipientUserId,
      recipientDeviceId: recipientDeviceId,
      messageV2: messageV2,
      senderKey: senderKey,
      priority: priority,
    );
  }

  static Future<VerifiedMessageEnvelope> verifyWithSenderKey({
    required String expectedGroupId,
    required String expectedConversationId,
    required String recipientUserId,
    required String recipientDeviceId,
    required Map<String, dynamic> messageV2,
    required GroupDeviceKeyEntry senderKey,
    int priority = 0,
  }) async {
    return PerformanceBenchmark.instance.measureAsync(
      'message_signature_verify',
      () async {
        final validated = _validate(
          expectedGroupId: expectedGroupId,
          expectedConversationId: expectedConversationId,
          recipientUserId: recipientUserId,
          recipientDeviceId: recipientDeviceId,
          messageV2: messageV2,
        );

        if (senderKey.userId != validated.senderUserId ||
            senderKey.deviceId != validated.senderDeviceId ||
            !const <String>{
              'active',
              'superseded',
              'revoked',
            }.contains(senderKey.status) ||
            senderKey.keyVersion != validated.senderKeyVersion) {
          throw const MessageAuthenticationException('sender_key_mismatch');
        }

        final publicKey = _decodeBase64(senderKey.pkSigB64, 32);
        final signature = _decodeBase64(_requiredString(messageV2, 'sig'), 64);
        final result = await CryptoIsolateService.instance.executeEd25519Verify(
          Ed25519VerifyTask(
            taskId: _nextTaskId('verify'),
            messageBytes: canonicalBytes(messageV2),
            signatureBytes: signature,
            publicKeyBytes: publicKey,
            priority: priority,
          ),
        );

        if (result.error != null || result.isValid != true) {
          throw const MessageAuthenticationException('invalid_signature');
        }

        return VerifiedMessageEnvelope._(
          messageId: validated.messageId,
          groupId: expectedGroupId,
          conversationId: expectedConversationId,
          senderUserId: validated.senderUserId,
          senderDeviceId: validated.senderDeviceId,
          recipientUserId: recipientUserId,
          recipientDeviceId: recipientDeviceId,
        );
      },
    );
  }

  /// Sérialisation historique V2. Elle reste inchangée pour conserver la
  /// compatibilité ; sa conception ambiguë sera remplacée par le protocole V3.
  static Uint8List canonicalBytes(Map<String, dynamic> payload) {
    final buffer = StringBuffer();
    buffer.write(payload['v']);
    final algorithms = Map<String, dynamic>.from(payload['alg'] as Map);
    buffer.write(algorithms['kem']);
    buffer.write(algorithms['kdf']);
    buffer.write(algorithms['aead']);
    buffer.write(algorithms['sig']);
    buffer.write(payload['groupId']);
    buffer.write(payload['convId']);
    buffer.write(payload['messageId']);
    buffer.write(payload['sentAt']);
    final sender = Map<String, dynamic>.from(payload['sender'] as Map);
    buffer.write(sender['userId']);
    buffer.write(sender['deviceId']);
    buffer.write(sender['eph_pub']);
    buffer.write(sender['key_version']);
    final recipients = payload['recipients'] as List<dynamic>;
    for (final recipient in recipients) {
      final map = Map<String, dynamic>.from(recipient as Map);
      buffer.write(map['userId']);
      buffer.write(map['deviceId']);
      if (map.containsKey('key_version')) {
        buffer.write(map['key_version']);
      }
      buffer.write(map['wrap']);
      buffer.write(map['nonce']);
    }
    buffer.write(payload['iv']);
    final ciphertext = payload['ciphertext'] as String;
    buffer.write(crypto.sha256.convert(utf8.encode(ciphertext)));
    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  static _ValidatedEnvelope _validate({
    required String expectedGroupId,
    required String expectedConversationId,
    required String recipientUserId,
    required String recipientDeviceId,
    required Map<String, dynamic> messageV2,
  }) {
    try {
      if (messageV2['v'] != 2) {
        throw const MessageAuthenticationException('unsupported_version');
      }

      final algorithms = Map<String, dynamic>.from(messageV2['alg'] as Map);
      for (final expected in _algorithms.entries) {
        if (algorithms[expected.key] != expected.value) {
          throw const MessageAuthenticationException('algorithm_mismatch');
        }
      }

      final groupId = _requiredString(messageV2, 'groupId');
      final conversationId = _requiredString(messageV2, 'convId');
      final messageId = _requiredString(messageV2, 'messageId');
      if (groupId != expectedGroupId ||
          conversationId != expectedConversationId) {
        throw const MessageAuthenticationException('context_mismatch');
      }
      final sentAt = messageV2['sentAt'];
      if (sentAt is! num ||
          !sentAt.isFinite ||
          sentAt != sentAt.toInt() ||
          sentAt.toInt() <= 0) {
        throw const MessageAuthenticationException('invalid_timestamp');
      }

      final sender = _sender(messageV2);
      final senderUserId = _requiredString(sender, 'userId');
      final senderDeviceId = _requiredString(sender, 'deviceId');
      final keyVersion = sender['key_version'];
      if (keyVersion is! num ||
          !keyVersion.isFinite ||
          keyVersion != keyVersion.toInt() ||
          keyVersion.toInt() < 1) {
        throw const MessageAuthenticationException('invalid_key_version');
      }
      _decodeBase64(_requiredString(sender, 'eph_pub'), 32);

      _decodeBase64(_requiredString(messageV2, 'iv'), 12);
      _decodeBase64(_requiredString(messageV2, 'salt'), 32);
      _decodeBase64(_requiredString(messageV2, 'sig'), 64);
      _decodeBase64AtLeast(_requiredString(messageV2, 'ciphertext'), 16);

      final recipients = messageV2['recipients'];
      if (recipients is! List<dynamic> || recipients.isEmpty) {
        throw const MessageAuthenticationException('invalid_recipients');
      }

      final seen = <String>{};
      var localRecipientCount = 0;
      for (final rawRecipient in recipients) {
        final recipient = Map<String, dynamic>.from(rawRecipient as Map);
        final userId = _requiredString(recipient, 'userId');
        final deviceId = _requiredString(recipient, 'deviceId');
        final recipientKeyVersion =
            recipient.containsKey('key_version')
                ? _positiveInteger(recipient['key_version'])
                : 1;
        if (!seen.add('$userId\u0000$deviceId')) {
          throw const MessageAuthenticationException('duplicate_recipient');
        }
        _decodeBase64AtLeast(_requiredString(recipient, 'wrap'), 16);
        _decodeBase64(_requiredString(recipient, 'nonce'), 12);
        if (userId == recipientUserId && deviceId == recipientDeviceId) {
          if (recipientKeyVersion < 1) {
            throw const MessageAuthenticationException('invalid_key_version');
          }
          localRecipientCount++;
        }
      }
      if (localRecipientCount != 1) {
        throw const MessageAuthenticationException('recipient_mismatch');
      }

      return _ValidatedEnvelope(
        messageId: messageId,
        senderUserId: senderUserId,
        senderDeviceId: senderDeviceId,
        senderKeyVersion: keyVersion.toInt(),
      );
    } on MessageAuthenticationException {
      rethrow;
    } catch (_) {
      throw const MessageAuthenticationException('invalid_envelope');
    }
  }

  static Map<String, dynamic> _sender(Map<String, dynamic> messageV2) {
    try {
      return Map<String, dynamic>.from(messageV2['sender'] as Map);
    } catch (_) {
      throw const MessageAuthenticationException('invalid_sender');
    }
  }

  static String _requiredString(Map<dynamic, dynamic> source, String key) {
    final value = source[key];
    if (value is! String || value.isEmpty) {
      throw const MessageAuthenticationException('invalid_envelope');
    }
    return value;
  }

  static int _positiveInteger(dynamic value) {
    if (value is! num ||
        !value.isFinite ||
        value != value.toInt() ||
        value.toInt() < 1) {
      throw const MessageAuthenticationException('invalid_key_version');
    }
    return value.toInt();
  }

  static Uint8List _decodeBase64(String value, int expectedLength) {
    final bytes = _decode(value);
    if (bytes.length != expectedLength) {
      throw const MessageAuthenticationException('invalid_encoding');
    }
    return bytes;
  }

  static Uint8List _decodeBase64AtLeast(String value, int minimumLength) {
    final bytes = _decode(value);
    if (bytes.length < minimumLength) {
      throw const MessageAuthenticationException('invalid_encoding');
    }
    return bytes;
  }

  static Uint8List _decode(String value) {
    try {
      var cleaned = value.trim().replaceAll(RegExp(r'[\s\n\r]'), '');
      if (!RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(cleaned)) {
        throw const FormatException();
      }
      cleaned = cleaned.replaceAll('-', '+').replaceAll('_', '/');
      while (cleaned.length % 4 != 0) {
        cleaned += '=';
      }
      return Uint8List.fromList(base64.decode(cleaned));
    } catch (_) {
      throw const MessageAuthenticationException('invalid_encoding');
    }
  }

  static String _nextTaskId(String operation) =>
      '$operation-${DateTime.now().microsecondsSinceEpoch}-${_taskSequence++}';
}

class _ValidatedEnvelope {
  const _ValidatedEnvelope({
    required this.messageId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.senderKeyVersion,
  });

  final String messageId;
  final String senderUserId;
  final String senderDeviceId;
  final int senderKeyVersion;
}
