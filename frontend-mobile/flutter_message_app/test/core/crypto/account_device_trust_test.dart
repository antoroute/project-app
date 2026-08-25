import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_message_app/core/crypto/account_device_identity_service.dart';
import 'package:flutter_message_app/core/models/account_device.dart';
import 'package:flutter_message_app/core/services/account_device_trust_service.dart';
import 'package:flutter_message_app/core/services/secure_string_store.dart';
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const accountId = '22222222-2222-4222-8222-222222222222';
  const currentDeviceId = '33333333-3333-4333-8333-333333333333';
  const pendingDeviceId = '44444444-4444-4444-8444-444444444444';

  group('identité Ed25519 du compte/appareil', () {
    test('la création est explicite, stable et isolée par compte', () async {
      final store = MemorySecureStringStore();
      final identities = AccountDeviceIdentityService.forTesting(
        storage: store,
      );

      await expectLater(
        identities.loadIdentity(accountId),
        throwsA(_identityError('missing_or_partial_key_material')),
      );
      expect(store.writeCount, 0);

      await identities.ensureIdentity(accountId);
      final firstPublic = await identities.publicKeyBase64(accountId);
      await identities.clearMemoryCache();
      final secondPublic = await identities.publicKeyBase64(accountId);

      expect(firstPublic, secondPublic);
      expect(base64Decode(firstPublic), hasLength(32));
      expect(store.writeCount, 2);
    });

    test(
      'une paire partielle ou incohérente échoue sans remplacement',
      () async {
        final store = MemorySecureStringStore(<String, String>{
          'account_device_identity_v1:account:$accountId:ed25519_seed':
              base64Encode(List<int>.filled(32, 7)),
        });
        final identities = AccountDeviceIdentityService.forTesting(
          storage: store,
        );

        await expectLater(
          identities.ensureIdentity(accountId),
          throwsA(_identityError('missing_or_partial_key_material')),
        );
        expect(store.writeCount, 0);
        expect(store.deleteCount, 0);
      },
    );
  });

  group('cycle de confiance client', () {
    test('l’auto-login ne génère ni identifiant ni clé manquante', () async {
      final deviceStore = MemorySecureStringStore();
      final identityStore = MemorySecureStringStore();
      final transport = FakeDeviceTrustTransport(accountId: accountId);
      final service = AccountDeviceTrustService(
        transport: transport,
        sessionDevices: SessionDeviceService.forTesting(
          storage: deviceStore,
          generateDeviceId: () => currentDeviceId,
        ),
        identities: AccountDeviceIdentityService.forTesting(
          storage: identityStore,
        ),
      );

      final result = await service.enrollOrRefresh(
        accountId: accountId,
        explicitEnrollment: false,
      );

      expect(result.state, DeviceTrustState.requiresEnrollment);
      expect(deviceStore.writeCount, 0);
      expect(identityStore.writeCount, 0);
      expect(transport.fetchCount, 0);
    });

    test('le premier appareil est prouvé puis devient actif', () async {
      final fixture = TrustFixture(accountId, currentDeviceId);

      final result = await fixture.service.enrollOrRefresh(
        accountId: accountId,
        explicitEnrollment: true,
        password: 'correct horse battery staple',
      );

      expect(result.state, DeviceTrustState.active);
      expect(result.deviceId, currentDeviceId);
      expect(fixture.transport.bootstrapPasswords, hasLength(1));
      expect(fixture.transport.registrationSignatureValid, isTrue);
      expect(fixture.identityStore.writeCount, 2);
    });

    test(
      'un appareil suivant reste pending et aucun grant n’est demandé',
      () async {
        final fixture = TrustFixture(accountId, currentDeviceId);
        fixture.transport.devices.add(
          fakeDevice(
            deviceId: pendingDeviceId,
            publicKey: base64Encode(List<int>.filled(32, 9)),
            status: AccountDeviceStatus.active,
            activated: true,
          ),
        );

        final result = await fixture.service.enrollOrRefresh(
          accountId: accountId,
          explicitEnrollment: true,
          password: 'not needed for a following device',
        );

        expect(result.state, DeviceTrustState.pending);
        expect(fixture.transport.bootstrapPasswords, isEmpty);
        expect(fixture.transport.registrationSignatureValid, isTrue);
      },
    );

    test('une approbation lie la cible affichée aux octets signés', () async {
      final fixture = TrustFixture(accountId, currentDeviceId);
      final enrolled = await fixture.service.enrollOrRefresh(
        accountId: accountId,
        explicitEnrollment: true,
        password: 'correct horse battery staple',
      );
      expect(enrolled.state, DeviceTrustState.active);

      final target = fakeDevice(
        deviceId: pendingDeviceId,
        publicKey: base64Encode(List<int>.generate(32, (index) => 32 + index)),
        status: AccountDeviceStatus.pending,
      );
      fixture.transport.devices.add(target);

      final result = await fixture.service.decide(
        accountId: accountId,
        approverDeviceId: currentDeviceId,
        target: target,
        decision: DeviceApprovalDecision.approve,
      );

      expect(result.state, DeviceTrustState.active);
      expect(fixture.transport.approvalSignatureValid, isTrue);
      expect(
        fixture.transport.devices
            .singleWhere((device) => device.deviceId == pendingDeviceId)
            .status,
        AccountDeviceStatus.active,
      );
    });

    test(
      'une décision différente dans la transcription est refusée avant signature',
      () async {
        final fixture = TrustFixture(accountId, currentDeviceId);
        await fixture.service.enrollOrRefresh(
          accountId: accountId,
          explicitEnrollment: true,
          password: 'correct horse battery staple',
        );
        final target = fakeDevice(
          deviceId: pendingDeviceId,
          publicKey: base64Encode(
            List<int>.generate(32, (index) => 32 + index),
          ),
          status: AccountDeviceStatus.pending,
        );
        fixture.transport.devices.add(target);
        fixture.transport.alterApprovalDecisionByte = true;

        await expectLater(
          fixture.service.decide(
            accountId: accountId,
            approverDeviceId: currentDeviceId,
            target: target,
            decision: DeviceApprovalDecision.approve,
          ),
          throwsA(_trustError('challenge_binding_mismatch')),
        );
        expect(fixture.transport.approvalSubmissions, 0);
      },
    );
  });
}

class TrustFixture {
  TrustFixture(this.accountId, this.deviceId)
    : deviceStore = MemorySecureStringStore(),
      identityStore = MemorySecureStringStore(),
      transport = FakeDeviceTrustTransport(accountId: accountId) {
    service = AccountDeviceTrustService(
      transport: transport,
      sessionDevices: SessionDeviceService.forTesting(
        storage: deviceStore,
        generateDeviceId: () => deviceId,
      ),
      identities: AccountDeviceIdentityService.forTesting(
        storage: identityStore,
      ),
    );
  }

  final String accountId;
  final String deviceId;
  final MemorySecureStringStore deviceStore;
  final MemorySecureStringStore identityStore;
  final FakeDeviceTrustTransport transport;
  late final AccountDeviceTrustService service;
}

class FakeDeviceTrustTransport implements DeviceTrustTransport {
  FakeDeviceTrustTransport({required this.accountId});

  final String accountId;
  final List<AccountDevice> devices = <AccountDevice>[];
  final List<String> bootstrapPasswords = <String>[];
  int fetchCount = 0;
  int approvalSubmissions = 0;
  bool registrationSignatureValid = false;
  bool approvalSignatureValid = false;
  bool alterApprovalDecisionByte = false;
  late Uint8List _registrationTranscript;
  late Uint8List _registrationPublicKey;
  late String _registrationDeviceId;
  late Uint8List _approvalTranscript;
  late AccountDevice _approvalTarget;
  late DeviceApprovalDecision _approvalDecision;

  @override
  Future<List<AccountDevice>> fetchDevices() async {
    fetchCount += 1;
    return List<AccountDevice>.of(devices);
  }

  @override
  Future<String> createBootstrapGrant(String password) async {
    bootstrapPasswords.add(password);
    return List<String>.filled(43, 'a').join();
  }

  @override
  Future<Map<String, dynamic>> createRegistrationChallenge({
    required String deviceId,
    required String identityPublicKey,
    required String platform,
    required String deviceName,
    String? bootstrapGrant,
  }) async {
    const challengeId = '11111111-1111-4111-8111-111111111111';
    _registrationDeviceId = deviceId;
    _registrationPublicKey = base64Decode(identityPublicKey);
    _registrationTranscript = Uint8List.fromList(<int>[
      ...ascii.encode('circlehaven/account-device-registration/v1\x00'),
      ...uuidBytes(challengeId),
      ...uuidBytes(accountId),
      ...uuidBytes(deviceId),
      ..._registrationPublicKey,
      ...List<int>.generate(32, (index) => 160 + index),
      ...uint64(2000000000),
    ]);
    return <String, dynamic>{
      'challengeId': challengeId,
      'deviceId': deviceId,
      'challenge': base64Encode(List<int>.generate(32, (index) => 160 + index)),
      'transcript': base64Encode(_registrationTranscript),
      'expiresAt':
          DateTime.fromMillisecondsSinceEpoch(
            2000000000 * 1000,
            isUtc: true,
          ).toIso8601String(),
      'algorithm': 'Ed25519',
      'platform': platform,
      'deviceName': deviceName,
    };
  }

  @override
  Future<Map<String, dynamic>> submitRegistrationProof({
    required String challengeId,
    required String signature,
  }) async {
    registrationSignatureValid = await Ed25519().verify(
      _registrationTranscript,
      signature: Signature(
        base64Decode(signature),
        publicKey: SimplePublicKey(
          _registrationPublicKey,
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!registrationSignatureValid) throw StateError('invalid signature');
    final status =
        devices.any((device) => device.activatedAt != null)
            ? AccountDeviceStatus.pending
            : AccountDeviceStatus.active;
    devices.add(
      fakeDevice(
        deviceId: _registrationDeviceId,
        publicKey: base64Encode(_registrationPublicKey),
        status: status,
        activated: status == AccountDeviceStatus.active,
      ),
    );
    return <String, dynamic>{
      'deviceId': _registrationDeviceId,
      'status': status.name,
      'bootstrap': status == AccountDeviceStatus.active,
    };
  }

  @override
  Future<Map<String, dynamic>> createApprovalChallenge({
    required String targetDeviceId,
    required String approverDeviceId,
    required DeviceApprovalDecision decision,
  }) async {
    const challengeId = '55555555-5555-4555-8555-555555555555';
    final approver = devices.singleWhere(
      (device) => device.deviceId == approverDeviceId,
    );
    _approvalTarget = devices.singleWhere(
      (device) => device.deviceId == targetDeviceId,
    );
    _approvalDecision = decision;
    _approvalTranscript = Uint8List.fromList(<int>[
      ...ascii.encode('circlehaven/account-device-approval/v1\x00'),
      ...uuidBytes(challengeId),
      ...uuidBytes(accountId),
      ...uuidBytes(approverDeviceId),
      ...uint32(approver.identityKeyVersion),
      ...base64Decode(approver.identityPublicKey),
      ...uuidBytes(targetDeviceId),
      ...uint32(_approvalTarget.identityKeyVersion),
      ...base64Decode(_approvalTarget.identityPublicKey),
      alterApprovalDecisionByte
          ? 2
          : (decision == DeviceApprovalDecision.approve ? 1 : 2),
      ...List<int>.generate(32, (index) => 96 + index),
      ...uint64(2000000000),
    ]);
    return <String, dynamic>{
      'challengeId': challengeId,
      'approverDeviceId': approverDeviceId,
      'targetDeviceId': targetDeviceId,
      'decision': decision.name,
      'transcript': base64Encode(_approvalTranscript),
      'expiresAt':
          DateTime.fromMillisecondsSinceEpoch(
            2000000000 * 1000,
            isUtc: true,
          ).toIso8601String(),
      'algorithm': 'Ed25519',
      'target': <String, dynamic>{
        'deviceId': _approvalTarget.deviceId,
        'identityPublicKey': _approvalTarget.identityPublicKey,
        'identityKeyVersion': _approvalTarget.identityKeyVersion,
        'platform': _approvalTarget.platform,
        'deviceName': _approvalTarget.deviceName,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> submitApprovalDecision({
    required String challengeId,
    required String signature,
  }) async {
    approvalSubmissions += 1;
    final approver = devices.singleWhere(
      (device) => device.status == AccountDeviceStatus.active,
    );
    approvalSignatureValid = await Ed25519().verify(
      _approvalTranscript,
      signature: Signature(
        base64Decode(signature),
        publicKey: SimplePublicKey(
          base64Decode(approver.identityPublicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!approvalSignatureValid) throw StateError('invalid signature');
    final status =
        _approvalDecision == DeviceApprovalDecision.approve
            ? AccountDeviceStatus.active
            : AccountDeviceStatus.revoked;
    final targetIndex = devices.indexWhere(
      (device) => device.deviceId == _approvalTarget.deviceId,
    );
    devices[targetIndex] = fakeDevice(
      deviceId: _approvalTarget.deviceId,
      publicKey: _approvalTarget.identityPublicKey,
      status: status,
      activated: status == AccountDeviceStatus.active,
    );
    return <String, dynamic>{
      'targetDeviceId': _approvalTarget.deviceId,
      'approverDeviceId': approver.deviceId,
      'decision': _approvalDecision.name,
      'status': status.name,
    };
  }
}

AccountDevice fakeDevice({
  required String deviceId,
  required String publicKey,
  required AccountDeviceStatus status,
  bool activated = false,
}) {
  final now = DateTime.utc(2030);
  return AccountDevice(
    deviceId: deviceId,
    identityPublicKey: publicKey,
    identityKeyVersion: 1,
    platform: 'windows',
    deviceName: 'Appareil de test',
    status: status,
    proofVerifiedAt: now,
    activatedAt: activated ? now : null,
    revokedAt: status == AccountDeviceStatus.revoked ? now : null,
    createdAt: now,
    updatedAt: now,
  );
}

List<int> uuidBytes(String value) => <int>[
  for (var index = 0; index < 32; index += 2)
    int.parse(value.replaceAll('-', '').substring(index, index + 2), radix: 16),
];

List<int> uint32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.big);
  return data.buffer.asUint8List();
}

List<int> uint64(int value) {
  final data = ByteData(8)..setUint64(0, value, Endian.big);
  return data.buffer.asUint8List();
}

Matcher _identityError(String code) => isA<AccountDeviceIdentityException>()
    .having((error) => error.code, 'code', code);

Matcher _trustError(String code) =>
    isA<DeviceTrustException>().having((error) => error.code, 'code', code);

class MemorySecureStringStore implements SecureStringStore {
  MemorySecureStringStore([Map<String, String>? initial])
    : values = <String, String>{...?initial};

  final Map<String, String> values;
  int writeCount = 0;
  int deleteCount = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writeCount += 1;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCount += 1;
    values.remove(key);
  }
}
