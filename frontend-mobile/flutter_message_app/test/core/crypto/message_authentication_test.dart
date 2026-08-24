import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_message_app/core/crypto/crypto_isolate_data.dart';
import 'package:flutter_message_app/core/crypto/crypto_isolate_service.dart';
import 'package:flutter_message_app/core/crypto/message_envelope_verifier.dart';
import 'package:flutter_message_app/core/services/key_directory_service.dart';
import 'package:flutter_message_app/core/services/performance_benchmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SimpleKeyPair signingKey;
  late GroupDeviceKeyEntry senderKey;
  late Map<String, dynamic> envelope;

  setUp(() async {
    signingKey = await Ed25519().newKeyPair();
    final publicKey = await signingKey.extractPublicKey();
    senderKey = GroupDeviceKeyEntry(
      userId: 'sender-user',
      deviceId: 'sender-device',
      pkSigB64: base64Encode(publicKey.bytes),
      pkKemB64: base64Encode(Uint8List(32)),
      keyVersion: 1,
      status: 'active',
      fingerprintSig: '',
      fingerprintKem: '',
    );
    envelope = await _signedEnvelope(signingKey);
  });

  tearDownAll(() async {
    await CryptoIsolateService.instance.dispose();
  });

  group('barrière Ed25519 et contexte', () {
    test('accepte une enveloppe V2 signée dans le contexte attendu', () async {
      final verified = await _verify(envelope, senderKey);

      expect(verified.messageId, 'message-1');
      expect(verified.conversationId, 'conversation-1');
      expect(verified.senderDeviceId, 'sender-device');
      expect(
        PerformanceBenchmark.instance.getStats(
          'message_signature_verify',
        )['count'],
        greaterThanOrEqualTo(1),
      );
    });

    test('vérifie deux fois le même message simultanément', () async {
      final verified = await Future.wait([
        _verify(envelope, senderKey),
        _verify(envelope, senderKey),
      ]);

      expect(verified, hasLength(2));
      expect(verified.every((item) => item.messageId == 'message-1'), isTrue);
    });

    test('rejette une signature altérée', () async {
      final signature = base64Decode(envelope['sig'] as String);
      signature[0] ^= 1;
      envelope['sig'] = base64Encode(signature);

      await expectLater(
        _verify(envelope, senderKey),
        throwsA(_authenticationCode('invalid_signature')),
      );
    });

    test('rejette une signature absente', () async {
      envelope.remove('sig');

      await expectLater(
        _verify(envelope, senderKey),
        throwsA(_authenticationCode('invalid_envelope')),
      );
    });

    test('rejette un cercle ou une conversation inattendus', () async {
      await expectLater(
        MessageEnvelopeVerifier.verifyWithSenderKey(
          expectedGroupId: 'another-group',
          expectedConversationId: 'conversation-1',
          recipientUserId: 'recipient-user',
          recipientDeviceId: 'recipient-device',
          messageV2: envelope,
          senderKey: senderKey,
        ),
        throwsA(_authenticationCode('context_mismatch')),
      );
    });

    test('rejette une enveloppe sans destinataire local unique', () async {
      envelope['recipients'] = [
        {
          'userId': 'another-user',
          'deviceId': 'another-device',
          'wrap': base64Encode(Uint8List(48)),
          'nonce': base64Encode(Uint8List(12)),
        },
      ];

      await expectLater(
        _verify(envelope, senderKey),
        throwsA(_authenticationCode('recipient_mismatch')),
      );
    });

    test('rejette un algorithme ou une version inattendus', () async {
      (envelope['alg'] as Map<String, dynamic>)['aead'] = 'AES-128-GCM';

      await expectLater(
        _verify(envelope, senderKey),
        throwsA(_authenticationCode('algorithm_mismatch')),
      );
    });

    test(
      'rejette une clé expéditeur inactive ou de mauvaise version',
      () async {
        final inactiveKey = GroupDeviceKeyEntry(
          userId: senderKey.userId,
          deviceId: senderKey.deviceId,
          pkSigB64: senderKey.pkSigB64,
          pkKemB64: senderKey.pkKemB64,
          keyVersion: 2,
          status: 'revoked',
          fingerprintSig: '',
          fingerprintKem: '',
        );

        await expectLater(
          _verify(envelope, inactiveKey),
          throwsA(_authenticationCode('sender_key_mismatch')),
        );
      },
    );
  });

  group('pipeline AEAD', () {
    test('ouvre un wrap et un contenu valides', () async {
      final fixture = await _pipelineFixture();
      final result = await CryptoIsolateService.instance.executeDecryptPipeline(
        fixture.task,
      );

      expect(utf8.decode(result.decryptedTextBytes!), 'message vérifié');
      expect(result.messageKeyBytes, fixture.messageKey);
    });

    test('rejette un wrap altéré', () async {
      final fixture = await _pipelineFixture();
      final altered = Uint8List.fromList(fixture.task.wrapBytes);
      altered[altered.length - 1] ^= 1;

      await expectLater(
        CryptoIsolateService.instance.executeDecryptPipeline(
          _copyTask(fixture.task, wrapBytes: altered),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('rejette un nonce de wrap altéré', () async {
      final fixture = await _pipelineFixture();
      final altered = Uint8List.fromList(fixture.task.wrapNonce);
      altered[0] ^= 1;

      await expectLater(
        CryptoIsolateService.instance.executeDecryptPipeline(
          _copyTask(fixture.task, wrapNonce: altered),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('rejette un sel HKDF altéré lors de l’ouverture du wrap', () async {
      final fixture = await _pipelineFixture();
      final altered = Uint8List.fromList(fixture.task.salt);
      altered[0] ^= 1;

      await expectLater(
        CryptoIsolateService.instance.executeDecryptPipeline(
          _copyTask(fixture.task, salt: altered),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('rejette un tag de contenu altéré sans remettre de texte', () async {
      final fixture = await _pipelineFixture();
      final altered = Uint8List.fromList(fixture.task.ciphertext);
      altered[altered.length - 1] ^= 1;

      await expectLater(
        CryptoIsolateService.instance.executeDecryptPipeline(
          _copyTask(fixture.task, ciphertext: altered),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}

Future<VerifiedMessageEnvelope> _verify(
  Map<String, dynamic> envelope,
  GroupDeviceKeyEntry senderKey,
) => MessageEnvelopeVerifier.verifyWithSenderKey(
  expectedGroupId: 'group-1',
  expectedConversationId: 'conversation-1',
  recipientUserId: 'recipient-user',
  recipientDeviceId: 'recipient-device',
  messageV2: envelope,
  senderKey: senderKey,
);

Matcher _authenticationCode(String code) =>
    isA<MessageAuthenticationException>().having(
      (error) => error.code,
      'code',
      code,
    );

Future<Map<String, dynamic>> _signedEnvelope(SimpleKeyPair signingKey) async {
  final payload = <String, dynamic>{
    'v': 2,
    'alg': {
      'kem': 'X25519',
      'kdf': 'HKDF-SHA256',
      'aead': 'AES-256-GCM',
      'sig': 'Ed25519',
    },
    'groupId': 'group-1',
    'convId': 'conversation-1',
    'messageId': 'message-1',
    'sentAt': 1700000000,
    'sender': {
      'userId': 'sender-user',
      'deviceId': 'sender-device',
      'eph_pub': base64Encode(Uint8List(32)),
      'key_version': 1,
    },
    'recipients': [
      {
        'userId': 'recipient-user',
        'deviceId': 'recipient-device',
        'wrap': base64Encode(Uint8List(48)),
        'nonce': base64Encode(Uint8List(12)),
      },
    ],
    'iv': base64Encode(Uint8List(12)),
    'ciphertext': base64Encode(Uint8List(32)),
    'salt': base64Encode(Uint8List(32)),
  };
  final signature = await Ed25519().sign(
    MessageEnvelopeVerifier.canonicalBytes(payload),
    keyPair: signingKey,
  );
  payload['sig'] = base64Encode(signature.bytes);
  return payload;
}

class _PipelineFixture {
  const _PipelineFixture(this.task, this.messageKey);

  final DecryptPipelineTask task;
  final Uint8List messageKey;
}

Future<_PipelineFixture> _pipelineFixture() async {
  final x25519 = X25519();
  final recipientKeyPair = await x25519.newKeyPair();
  final recipientPrivateKey = Uint8List.fromList(
    await recipientKeyPair.extractPrivateKeyBytes(),
  );
  final ephemeralKeyPair = await x25519.newKeyPair();
  final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
  final sharedSecret = await x25519.sharedSecretKey(
    keyPair: ephemeralKeyPair,
    remotePublicKey: await recipientKeyPair.extractPublicKey(),
  );

  final salt = Uint8List.fromList(List<int>.generate(32, (index) => index));
  final wrappingKey = await Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 32,
  ).deriveKey(
    secretKey: sharedSecret,
    nonce: salt,
    info: utf8.encode(
      'project-app/v2 group-1 conversation-1 recipient-user recipient-device',
    ),
  );
  final messageKey = Uint8List.fromList(
    List<int>.generate(32, (index) => index + 1),
  );
  final wrapNonce = Uint8List.fromList(List<int>.filled(12, 7));
  final contentNonce = Uint8List.fromList(List<int>.filled(12, 9));
  final aead = AesGcm.with256bits();
  final wrap = await aead.encrypt(
    messageKey,
    secretKey: wrappingKey,
    nonce: wrapNonce,
  );
  final content = await aead.encrypt(
    utf8.encode('message vérifié'),
    secretKey: SecretKey(messageKey),
    nonce: contentNonce,
  );

  return _PipelineFixture(
    DecryptPipelineTask(
      taskId: 'pipeline-${DateTime.now().microsecondsSinceEpoch}',
      myPrivateKeyBytes: recipientPrivateKey,
      remotePublicKeyBytes: Uint8List.fromList(ephemeralPublicKey.bytes),
      groupId: 'group-1',
      convId: 'conversation-1',
      myUserId: 'recipient-user',
      myDeviceId: 'recipient-device',
      salt: salt,
      wrapBytes: Uint8List.fromList(wrap.cipherText + wrap.mac.bytes),
      wrapNonce: wrapNonce,
      iv: contentNonce,
      ciphertext: Uint8List.fromList(content.cipherText + content.mac.bytes),
    ),
    messageKey,
  );
}

DecryptPipelineTask _copyTask(
  DecryptPipelineTask source, {
  Uint8List? wrapBytes,
  Uint8List? wrapNonce,
  Uint8List? salt,
  Uint8List? ciphertext,
}) => DecryptPipelineTask(
  taskId: '${source.taskId}-altered',
  myPrivateKeyBytes: source.myPrivateKeyBytes,
  remotePublicKeyBytes: source.remotePublicKeyBytes,
  groupId: source.groupId,
  convId: source.convId,
  myUserId: source.myUserId,
  myDeviceId: source.myDeviceId,
  salt: salt ?? source.salt,
  wrapBytes: wrapBytes ?? source.wrapBytes,
  wrapNonce: wrapNonce ?? source.wrapNonce,
  iv: source.iv,
  ciphertext: ciphertext ?? source.ciphertext,
);
