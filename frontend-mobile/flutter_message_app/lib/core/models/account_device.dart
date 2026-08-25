import 'dart:convert';

import 'package:crypto/crypto.dart';

enum AccountDeviceStatus { pending, active, revoked }

class AccountDevice {
  const AccountDevice({
    required this.deviceId,
    required this.identityPublicKey,
    required this.identityKeyVersion,
    required this.platform,
    required this.deviceName,
    required this.status,
    required this.proofVerifiedAt,
    required this.activatedAt,
    required this.revokedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String deviceId;
  final String identityPublicKey;
  final int identityKeyVersion;
  final String platform;
  final String deviceName;
  final AccountDeviceStatus status;
  final DateTime proofVerifiedAt;
  final DateTime? activatedAt;
  final DateTime? revokedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory AccountDevice.fromJson(Map<String, dynamic> json) {
    DateTime? optionalDate(String key) {
      final value = json[key];
      return value is String ? DateTime.parse(value) : null;
    }

    final statusValue = json['status'] as String?;
    final status = switch (statusValue) {
      'pending' => AccountDeviceStatus.pending,
      'active' => AccountDeviceStatus.active,
      'revoked' => AccountDeviceStatus.revoked,
      _ => throw const FormatException('invalid account device status'),
    };
    final publicKey = json['identityPublicKey'] as String;
    final publicKeyBytes = base64Decode(publicKey);
    if (base64Encode(publicKeyBytes) != publicKey ||
        publicKeyBytes.length != 32) {
      throw const FormatException('invalid account device public key');
    }

    return AccountDevice(
      deviceId: json['deviceId'] as String,
      identityPublicKey: publicKey,
      identityKeyVersion: json['identityKeyVersion'] as int,
      platform: json['platform'] as String,
      deviceName: json['deviceName'] as String,
      status: status,
      proofVerifiedAt: DateTime.parse(json['proofVerifiedAt'] as String),
      activatedAt: optionalDate('activatedAt'),
      revokedAt: optionalDate('revokedAt'),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  String get fingerprint {
    final digest = sha256.convert(base64Decode(identityPublicKey)).bytes;
    return digest
        .take(8)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase()
        .replaceAllMapped(RegExp(r'.{4}'), (match) => '${match.group(0)} ')
        .trim();
  }
}
