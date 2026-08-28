import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_message_app/config/constants.dart';
import 'package:flutter_message_app/core/crypto/account_device_identity_service.dart';
import 'package:flutter_message_app/core/models/account_device.dart';
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'package:http/http.dart' as http;

enum DeviceTrustState {
  unauthenticated,
  checking,
  requiresEnrollment,
  pending,
  active,
  revoked,
  error,
}

enum DeviceApprovalDecision { approve, reject, revoke }

class DeviceTrustException implements Exception {
  const DeviceTrustException(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  @override
  String toString() => 'DeviceTrustException($code)';
}

class DeviceTrustResult {
  const DeviceTrustResult({required this.state, this.device, this.deviceId});

  final DeviceTrustState state;
  final AccountDevice? device;
  final String? deviceId;
}

abstract interface class DeviceTrustTransport {
  Future<List<AccountDevice>> fetchDevices();
  Future<String> createBootstrapGrant(String password);
  Future<Map<String, dynamic>> createRegistrationChallenge({
    required String deviceId,
    required String identityPublicKey,
    required String platform,
    required String deviceName,
    String? bootstrapGrant,
  });
  Future<Map<String, dynamic>> submitRegistrationProof({
    required String challengeId,
    required String signature,
  });
  Future<Map<String, dynamic>> createApprovalChallenge({
    required String targetDeviceId,
    required String approverDeviceId,
    required DeviceApprovalDecision decision,
  });
  Future<Map<String, dynamic>> submitApprovalDecision({
    required String challengeId,
    required String signature,
  });
}

class HttpDeviceTrustTransport implements DeviceTrustTransport {
  HttpDeviceTrustTransport({
    required Future<Map<String, String>> Function() headers,
    http.Client? client,
  }) : _headers = headers,
       _client = client ?? http.Client();

  final Future<Map<String, String>> Function() _headers;
  final http.Client _client;

  Map<String, dynamic> _object(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const DeviceTrustException('invalid_server_response');
    }
    return decoded;
  }

  Never _throwResponse(http.Response response) {
    String code = 'device_trust_request_failed';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        code = decoded['error'] as String;
      }
    } catch (_) {
      // Le statut HTTP reste disponible sans exposer le corps de réponse.
    }
    throw DeviceTrustException(code, statusCode: response.statusCode);
  }

  @override
  Future<List<AccountDevice>> fetchDevices() async {
    final response = await _client.get(
      Uri.parse('$messagingBase/devices'),
      headers: await _headers(),
    );
    if (response.statusCode != 200) _throwResponse(response);
    final decoded = jsonDecode(response.body);
    if (decoded is! List<dynamic>) {
      throw const DeviceTrustException('invalid_server_response');
    }
    return decoded
        .map((item) => AccountDevice.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<String> createBootstrapGrant(String password) async {
    final response = await _client.post(
      Uri.parse('$authBase/device-bootstrap-grant'),
      headers: await _headers(),
      body: jsonEncode(<String, String>{'password': password}),
    );
    if (response.statusCode != 201) _throwResponse(response);
    final body = _object(response);
    final grant = body['grant'];
    if (grant is! String || grant.length != 43) {
      throw const DeviceTrustException('invalid_server_response');
    }
    return grant;
  }

  @override
  Future<Map<String, dynamic>> createRegistrationChallenge({
    required String deviceId,
    required String identityPublicKey,
    required String platform,
    required String deviceName,
    String? bootstrapGrant,
  }) async {
    final body = <String, dynamic>{
      'deviceId': deviceId,
      'identityPublicKey': identityPublicKey,
      'platform': platform,
      'deviceName': deviceName,
      if (bootstrapGrant != null) 'bootstrapGrant': bootstrapGrant,
    };
    final response = await _client.post(
      Uri.parse('$messagingBase/devices/registrations/challenge'),
      headers: await _headers(),
      body: jsonEncode(body),
    );
    if (response.statusCode != 201) _throwResponse(response);
    return _object(response);
  }

  @override
  Future<Map<String, dynamic>> submitRegistrationProof({
    required String challengeId,
    required String signature,
  }) async {
    final response = await _client.post(
      Uri.parse('$messagingBase/devices/registrations/$challengeId/proof'),
      headers: await _headers(),
      body: jsonEncode(<String, String>{'signature': signature}),
    );
    if (response.statusCode != 201) _throwResponse(response);
    return _object(response);
  }

  @override
  Future<Map<String, dynamic>> createApprovalChallenge({
    required String targetDeviceId,
    required String approverDeviceId,
    required DeviceApprovalDecision decision,
  }) async {
    final response = await _client.post(
      Uri.parse('$messagingBase/devices/$targetDeviceId/approvals/challenge'),
      headers: await _headers(),
      body: jsonEncode(<String, String>{
        'approverDeviceId': approverDeviceId,
        'decision': decision.name,
      }),
    );
    if (response.statusCode != 201) _throwResponse(response);
    return _object(response);
  }

  @override
  Future<Map<String, dynamic>> submitApprovalDecision({
    required String challengeId,
    required String signature,
  }) async {
    final response = await _client.post(
      Uri.parse('$messagingBase/devices/approvals/$challengeId/decision'),
      headers: await _headers(),
      body: jsonEncode(<String, String>{'signature': signature}),
    );
    if (response.statusCode != 200) _throwResponse(response);
    return _object(response);
  }
}

class AccountDeviceTrustService {
  AccountDeviceTrustService({
    required DeviceTrustTransport transport,
    SessionDeviceService? sessionDevices,
    AccountDeviceIdentityService? identities,
  }) : _transport = transport,
       _sessionDevices = sessionDevices ?? SessionDeviceService.instance,
       _identities = identities ?? AccountDeviceIdentityService.instance;

  final DeviceTrustTransport _transport;
  final SessionDeviceService _sessionDevices;
  final AccountDeviceIdentityService _identities;

  String get platform => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.windows => 'windows',
    TargetPlatform.macOS => 'macos',
    _ => 'unknown',
  };

  String get defaultDeviceName => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Téléphone Android',
    TargetPlatform.iOS => 'iPhone ou iPad',
    TargetPlatform.windows => 'PC Windows',
    TargetPlatform.macOS => 'Mac',
    _ => 'Appareil CircleHaven',
  };

  Future<DeviceTrustResult> enrollOrRefresh({
    required String accountId,
    required bool explicitEnrollment,
    String? password,
  }) async {
    final deviceId =
        explicitEnrollment
            ? await _sessionDevices.getOrCreateDeviceId(accountId)
            : await _sessionDevices.loadDeviceId(accountId);
    if (deviceId == null) {
      return const DeviceTrustResult(
        state: DeviceTrustState.requiresEnrollment,
      );
    }

    if (explicitEnrollment) {
      await _identities.ensureIdentity(accountId);
    } else {
      try {
        await _identities.loadIdentity(accountId);
      } on AccountDeviceIdentityException catch (error) {
        if (error.code == 'missing_or_partial_key_material') {
          return DeviceTrustResult(
            state: DeviceTrustState.requiresEnrollment,
            deviceId: deviceId,
          );
        }
        rethrow;
      }
    }
    final identityPublicKey = await _identities.publicKeyBase64(accountId);
    List<AccountDevice> devices;
    try {
      devices = await _transport.fetchDevices();
    } on DeviceTrustException catch (error) {
      if (!explicitEnrollment ||
          error.code != 'device_authorization_required') {
        rethrow;
      }
      // Un appareil pas encore inscrit ne peut pas produire une preuve d'accès
      // reconnue. Le challenge d'inscription décidera lui-même si le bootstrap
      // est encore permis.
      devices = const <AccountDevice>[];
    }
    final current = _findCurrent(devices, deviceId);
    if (current != null) {
      if (current.identityPublicKey != identityPublicKey) {
        throw const DeviceTrustException('local_server_identity_mismatch');
      }
      return _result(current);
    }

    if (!explicitEnrollment) {
      return DeviceTrustResult(
        state: DeviceTrustState.requiresEnrollment,
        deviceId: deviceId,
      );
    }

    final isBootstrap = !devices.any((device) => device.activatedAt != null);
    if (isBootstrap && (password == null || password.isEmpty)) {
      return DeviceTrustResult(
        state: DeviceTrustState.requiresEnrollment,
        deviceId: deviceId,
      );
    }
    final bootstrapGrant =
        isBootstrap ? await _transport.createBootstrapGrant(password!) : null;
    final challenge = await _transport.createRegistrationChallenge(
      deviceId: deviceId,
      identityPublicKey: identityPublicKey,
      platform: platform,
      deviceName: defaultDeviceName,
      bootstrapGrant: bootstrapGrant,
    );
    if (challenge['deviceId'] != deviceId ||
        challenge['algorithm'] != 'Ed25519' ||
        challenge['challengeId'] is! String ||
        challenge['transcript'] is! String) {
      throw const DeviceTrustException('invalid_registration_challenge');
    }
    _validateRegistrationTranscript(
      challenge: challenge,
      accountId: accountId,
      deviceId: deviceId,
      identityPublicKey: identityPublicKey,
    );
    final signature = await _identities.signBase64Transcript(
      accountId,
      challenge['transcript'] as String,
      expectedLength: 163,
    );
    final proof = await _transport.submitRegistrationProof(
      challengeId: challenge['challengeId'] as String,
      signature: signature,
    );
    if (proof['deviceId'] != deviceId || proof['status'] is! String) {
      throw const DeviceTrustException('invalid_registration_result');
    }

    final refreshed = await _transport.fetchDevices();
    final registered = _findCurrent(refreshed, deviceId);
    if (registered == null ||
        registered.identityPublicKey != identityPublicKey) {
      throw const DeviceTrustException('registration_not_visible');
    }
    return _result(registered);
  }

  Future<List<AccountDevice>> fetchDevices() => _transport.fetchDevices();

  Future<DeviceTrustResult> refreshCurrent({required String accountId}) async {
    return enrollOrRefresh(accountId: accountId, explicitEnrollment: false);
  }

  Future<DeviceTrustResult> decide({
    required String accountId,
    required String approverDeviceId,
    required AccountDevice target,
    required DeviceApprovalDecision decision,
  }) async {
    final localDeviceId = await _sessionDevices.loadDeviceId(accountId);
    if (localDeviceId != approverDeviceId) {
      throw const DeviceTrustException('approver_is_not_current_device');
    }
    final localIdentityPublicKey = await _identities.publicKeyBase64(accountId);
    final devices = await _transport.fetchDevices();
    final approver = _findCurrent(devices, approverDeviceId);
    if (approver == null ||
        approver.status != AccountDeviceStatus.active ||
        approver.identityPublicKey != localIdentityPublicKey) {
      throw const DeviceTrustException('approver_device_not_active');
    }
    final challenge = await _transport.createApprovalChallenge(
      targetDeviceId: target.deviceId,
      approverDeviceId: approverDeviceId,
      decision: decision,
    );
    final responseTarget = challenge['target'];
    if (challenge['challengeId'] is! String ||
        challenge['transcript'] is! String ||
        challenge['algorithm'] != 'Ed25519' ||
        challenge['approverDeviceId'] != approverDeviceId ||
        challenge['targetDeviceId'] != target.deviceId ||
        challenge['decision'] != decision.name ||
        responseTarget is! Map<String, dynamic> ||
        responseTarget['deviceId'] != target.deviceId ||
        responseTarget['identityPublicKey'] != target.identityPublicKey ||
        responseTarget['identityKeyVersion'] != target.identityKeyVersion) {
      throw const DeviceTrustException('invalid_approval_challenge');
    }
    _validateApprovalTranscript(
      challenge: challenge,
      accountId: accountId,
      approver: approver,
      target: target,
      decision: decision,
    );
    final signature = await _identities.signBase64Transcript(
      accountId,
      challenge['transcript'] as String,
      expectedLength: 216,
    );
    final result = await _transport.submitApprovalDecision(
      challengeId: challenge['challengeId'] as String,
      signature: signature,
    );
    final expectedStatus =
        decision == DeviceApprovalDecision.approve ? 'active' : 'revoked';
    if (result['targetDeviceId'] != target.deviceId ||
        result['approverDeviceId'] != approverDeviceId ||
        result['decision'] != decision.name ||
        result['status'] != expectedStatus) {
      throw const DeviceTrustException('invalid_approval_result');
    }
    return refreshCurrent(accountId: accountId);
  }

  AccountDevice? _findCurrent(List<AccountDevice> devices, String deviceId) {
    for (final device in devices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  Uint8List _canonicalTranscript(
    Map<String, dynamic> challenge,
    int expectedLength,
  ) {
    final value = challenge['transcript'];
    if (value is! String) {
      throw const DeviceTrustException('invalid_challenge_transcript');
    }
    try {
      final bytes = base64Decode(value);
      if (bytes.length != expectedLength || base64Encode(bytes) != value) {
        throw const FormatException();
      }
      return bytes;
    } on FormatException {
      throw const DeviceTrustException('invalid_challenge_transcript');
    }
  }

  Uint8List _uuidBytes(String value) {
    final compact = value.replaceAll('-', '');
    if (compact.length != 32) {
      throw const DeviceTrustException('invalid_challenge_identifier');
    }
    try {
      return Uint8List.fromList(<int>[
        for (var index = 0; index < compact.length; index += 2)
          int.parse(compact.substring(index, index + 2), radix: 16),
      ]);
    } on FormatException {
      throw const DeviceTrustException('invalid_challenge_identifier');
    }
  }

  Uint8List _publicKeyBytes(String value) {
    try {
      final bytes = base64Decode(value);
      if (bytes.length != 32 || base64Encode(bytes) != value) {
        throw const FormatException();
      }
      return bytes;
    } on FormatException {
      throw const DeviceTrustException('invalid_challenge_public_key');
    }
  }

  void _expectSlice(Uint8List transcript, int offset, List<int> expected) {
    if (!listEquals(
      transcript.sublist(offset, offset + expected.length),
      expected,
    )) {
      throw const DeviceTrustException('challenge_binding_mismatch');
    }
  }

  void _expectExpiration(
    Uint8List transcript,
    int offset,
    Map<String, dynamic> challenge,
  ) {
    final expiresAt = challenge['expiresAt'];
    if (expiresAt is! String) {
      throw const DeviceTrustException('invalid_challenge_expiration');
    }
    try {
      final expected = DateTime.parse(expiresAt).millisecondsSinceEpoch ~/ 1000;
      final data = ByteData.sublistView(transcript, offset, offset + 8);
      if (data.getUint64(0, Endian.big) != expected) {
        throw const DeviceTrustException('challenge_binding_mismatch');
      }
    } on FormatException {
      throw const DeviceTrustException('invalid_challenge_expiration');
    }
  }

  void _validateRegistrationTranscript({
    required Map<String, dynamic> challenge,
    required String accountId,
    required String deviceId,
    required String identityPublicKey,
  }) {
    final transcript = _canonicalTranscript(challenge, 163);
    _expectSlice(
      transcript,
      0,
      ascii.encode('circlehaven/account-device-registration/v1\x00'),
    );
    _expectSlice(
      transcript,
      43,
      _uuidBytes(challenge['challengeId'] as String),
    );
    _expectSlice(transcript, 59, _uuidBytes(accountId));
    _expectSlice(transcript, 75, _uuidBytes(deviceId));
    _expectSlice(transcript, 91, _publicKeyBytes(identityPublicKey));
    _expectExpiration(transcript, 155, challenge);
  }

  void _validateApprovalTranscript({
    required Map<String, dynamic> challenge,
    required String accountId,
    required AccountDevice approver,
    required AccountDevice target,
    required DeviceApprovalDecision decision,
  }) {
    final transcript = _canonicalTranscript(challenge, 216);
    _expectSlice(
      transcript,
      0,
      ascii.encode('circlehaven/account-device-approval/v1\x00'),
    );
    _expectSlice(
      transcript,
      39,
      _uuidBytes(challenge['challengeId'] as String),
    );
    _expectSlice(transcript, 55, _uuidBytes(accountId));
    _expectSlice(transcript, 71, _uuidBytes(approver.deviceId));
    final approverVersion = ByteData.sublistView(transcript, 87, 91);
    if (approverVersion.getUint32(0, Endian.big) !=
        approver.identityKeyVersion) {
      throw const DeviceTrustException('challenge_binding_mismatch');
    }
    _expectSlice(transcript, 91, _publicKeyBytes(approver.identityPublicKey));
    _expectSlice(transcript, 123, _uuidBytes(target.deviceId));
    final targetVersion = ByteData.sublistView(transcript, 139, 143);
    if (targetVersion.getUint32(0, Endian.big) != target.identityKeyVersion) {
      throw const DeviceTrustException('challenge_binding_mismatch');
    }
    _expectSlice(transcript, 143, _publicKeyBytes(target.identityPublicKey));
    final expectedDecision = switch (decision) {
      DeviceApprovalDecision.approve => 1,
      DeviceApprovalDecision.reject => 2,
      DeviceApprovalDecision.revoke => 3,
    };
    if (transcript[175] != expectedDecision) {
      throw const DeviceTrustException('challenge_binding_mismatch');
    }
    _expectExpiration(transcript, 208, challenge);
  }

  DeviceTrustResult _result(AccountDevice device) => DeviceTrustResult(
    state: switch (device.status) {
      AccountDeviceStatus.pending => DeviceTrustState.pending,
      AccountDeviceStatus.active => DeviceTrustState.active,
      AccountDeviceStatus.revoked => DeviceTrustState.revoked,
    },
    device: device,
    deviceId: device.deviceId,
  );
}
