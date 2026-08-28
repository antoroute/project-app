import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_message_app/core/services/secure_string_store.dart';

class AccountDeviceIdentityException implements Exception {
  const AccountDeviceIdentityException(this.code);

  final String code;

  @override
  String toString() => 'AccountDeviceIdentityException($code)';
}

class AccountDeviceIdentityService {
  AccountDeviceIdentityService._internal({SecureStringStore? storage})
    : _storage = storage ?? PlatformSecureStringStore();

  static final AccountDeviceIdentityService instance =
      AccountDeviceIdentityService._internal();

  factory AccountDeviceIdentityService.forTesting({
    required SecureStringStore storage,
  }) => AccountDeviceIdentityService._internal(storage: storage);

  final SecureStringStore _storage;
  final Map<String, SimpleKeyPair> _cache = <String, SimpleKeyPair>{};
  final Map<String, Future<SimpleKeyPair>> _pending =
      <String, Future<SimpleKeyPair>>{};

  static final RegExp _accountIdPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  String _key(String accountId, String kind) =>
      'account_device_identity_v1:account:$accountId:$kind';

  void _validateAccountId(String accountId) {
    if (!_accountIdPattern.hasMatch(accountId)) {
      throw ArgumentError.value(accountId, 'accountId', 'invalid account UUID');
    }
  }

  Future<SimpleKeyPair> ensureIdentity(String accountId) =>
      _serialized(accountId, () => _loadOrCreate(accountId));

  Future<SimpleKeyPair> loadIdentity(String accountId) =>
      _serialized(accountId, () => _load(accountId));

  Future<SimpleKeyPair> _serialized(
    String accountId,
    Future<SimpleKeyPair> Function() operation,
  ) async {
    _validateAccountId(accountId);
    final cached = _cache[accountId];
    if (cached != null) return cached;
    final existing = _pending[accountId];
    if (existing != null) return existing;

    final future = operation();
    _pending[accountId] = future;
    try {
      return await future;
    } finally {
      if (identical(_pending[accountId], future)) _pending.remove(accountId);
    }
  }

  Future<SimpleKeyPair> _loadOrCreate(String accountId) async {
    final material = await _readMaterial(accountId);
    if (material.every((value) => value == null)) {
      final keyPair = await Ed25519().newKeyPair();
      final seed = await keyPair.extractPrivateKeyBytes();
      final publicKey = await keyPair.extractPublicKey();
      await _storage.write(_key(accountId, 'ed25519_seed'), base64Encode(seed));
      await _storage.write(
        _key(accountId, 'ed25519_public'),
        base64Encode(publicKey.bytes),
      );
      _cache[accountId] = keyPair;
      return keyPair;
    }
    return _validateAndCache(accountId, material);
  }

  Future<SimpleKeyPair> _load(String accountId) async {
    return _validateAndCache(accountId, await _readMaterial(accountId));
  }

  Future<List<String?>> _readMaterial(String accountId) =>
      Future.wait(<Future<String?>>[
        _storage.read(_key(accountId, 'ed25519_seed')),
        _storage.read(_key(accountId, 'ed25519_public')),
      ]);

  Uint8List _decode32(String value) {
    try {
      final bytes = base64Decode(value);
      if (base64Encode(bytes) != value || bytes.length != 32) {
        throw const AccountDeviceIdentityException('invalid_key_material');
      }
      return bytes;
    } on AccountDeviceIdentityException {
      rethrow;
    } on FormatException {
      throw const AccountDeviceIdentityException('invalid_key_material');
    }
  }

  Future<SimpleKeyPair> _validateAndCache(
    String accountId,
    List<String?> material,
  ) async {
    if (material.any((value) => value == null)) {
      throw const AccountDeviceIdentityException(
        'missing_or_partial_key_material',
      );
    }
    final seed = _decode32(material[0]!);
    final storedPublic = _decode32(material[1]!);
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final derivedPublic = await keyPair.extractPublicKey();
    if (!listEquals(storedPublic, derivedPublic.bytes)) {
      throw const AccountDeviceIdentityException('public_key_mismatch');
    }
    _cache[accountId] = keyPair;
    return keyPair;
  }

  Future<String> publicKeyBase64(String accountId) async {
    final keyPair = await loadIdentity(accountId);
    return base64Encode((await keyPair.extractPublicKey()).bytes);
  }

  Future<String> signBase64Transcript(
    String accountId,
    String transcriptBase64, {
    required int expectedLength,
  }) async {
    Uint8List transcript;
    try {
      transcript = base64Decode(transcriptBase64);
      if (base64Encode(transcript) != transcriptBase64 ||
          transcript.length != expectedLength) {
        throw const FormatException();
      }
    } on FormatException {
      throw const AccountDeviceIdentityException('invalid_transcript');
    }
    final signature = await Ed25519().sign(
      transcript,
      keyPair: await loadIdentity(accountId),
    );
    return base64Encode(signature.bytes);
  }

  Uint8List _uuidBytes(String value) {
    if (!_accountIdPattern.hasMatch(value)) {
      throw const AccountDeviceIdentityException('invalid_uuid');
    }
    final compact = value.replaceAll('-', '');
    return Uint8List.fromList(<int>[
      for (var index = 0; index < compact.length; index += 2)
        int.parse(compact.substring(index, index + 2), radix: 16),
    ]);
  }

  Uint8List _uint32(int value) {
    if (value < 1 || value > 0xffffffff) {
      throw const AccountDeviceIdentityException('invalid_key_version');
    }
    final bytes = ByteData(4)..setUint32(0, value, Endian.big);
    return bytes.buffer.asUint8List();
  }

  Uint8List _canonicalKey(String value) {
    try {
      final bytes = base64Decode(value);
      if (bytes.length != 32 || base64Encode(bytes) != value) {
        throw const FormatException();
      }
      return bytes;
    } on FormatException {
      throw const AccountDeviceIdentityException('invalid_public_key');
    }
  }

  Future<String> signDeviceAccess({
    required String accountId,
    required String deviceId,
    required int identityKeyVersion,
    required String accessTokenId,
  }) async {
    final transcript =
        BytesBuilder(copy: false)
          ..add(ascii.encode('circlehaven/account-device-access/v1\x00'))
          ..add(_uuidBytes(accountId))
          ..add(_uuidBytes(deviceId))
          ..add(_uint32(identityKeyVersion))
          ..add(_uuidBytes(accessTokenId));
    final bytes = transcript.takeBytes();
    if (bytes.length != 89) {
      throw const AccountDeviceIdentityException(
        'invalid_device_access_transcript',
      );
    }
    final signature = await Ed25519().sign(
      bytes,
      keyPair: await loadIdentity(accountId),
    );
    return base64Encode(signature.bytes);
  }

  Future<String> signGroupDeviceKeyBinding({
    required String accountId,
    required String groupId,
    required String deviceId,
    required int identityKeyVersion,
    required int keyVersion,
    required String signaturePublicKey,
    required String kemPublicKey,
  }) async {
    final transcript =
        BytesBuilder(copy: false)
          ..add(ascii.encode('circlehaven/group-device-key/v1\x00'))
          ..add(_uuidBytes(accountId))
          ..add(_uuidBytes(groupId))
          ..add(_uuidBytes(deviceId))
          ..add(_uint32(identityKeyVersion))
          ..add(_uint32(keyVersion))
          ..add(_canonicalKey(signaturePublicKey))
          ..add(_canonicalKey(kemPublicKey));
    final bytes = transcript.takeBytes();
    if (bytes.length != 152) {
      throw const AccountDeviceIdentityException(
        'invalid_group_device_key_transcript',
      );
    }
    final signature = await Ed25519().sign(
      bytes,
      keyPair: await loadIdentity(accountId),
    );
    return base64Encode(signature.bytes);
  }

  Future<void> clearMemoryCache() async {
    final pending = _pending.values.toList(growable: false);
    try {
      await Future.wait(pending);
    } catch (_) {
      // La purge mémoire ne doit pas être bloquée par un chargement échoué.
    } finally {
      _cache.clear();
    }
  }
}
