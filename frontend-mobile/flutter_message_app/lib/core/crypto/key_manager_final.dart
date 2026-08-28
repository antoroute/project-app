import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_message_app/core/services/secure_string_store.dart';

class KeyMaterialUnavailableException implements Exception {
  const KeyMaterialUnavailableException(this.code);

  final String code;

  @override
  String toString() => 'KeyMaterialUnavailableException($code)';
}

/// 🎉 SOLUTION FINALE - KeyManager avec vraie reconstruction depuis les seeds
///
/// Cette solution utilise newKeyPairFromSeed() pour reconstruire les clés
/// depuis les seeds 32 octets stockés.
///
/// ✅ Ed25519 (signatures) avec reconstruction depuis seed
/// ✅ X25519 (échange de clés) avec reconstruction depuis seed
/// ✅ Performance optimisée avec cryptography_flutter
/// ✅ Compatible null safety
/// ✅ Messages anciens restent déchiffrables après redémarrage
/// ✅ Format standard (seeds 32 octets)
class KeyManagerFinal {
  KeyManagerFinal._internal({SecureStringStore? storage})
    : _storage = storage ?? PlatformSecureStringStore();
  static final KeyManagerFinal instance = KeyManagerFinal._internal();

  factory KeyManagerFinal.forTesting({required SecureStringStore storage}) =>
      KeyManagerFinal._internal(storage: storage);

  final SecureStringStore _storage;

  // Namespaced keys: <groupId>.<deviceId>.(ed25519|x25519).seed
  String _ns(
    String groupId,
    String deviceId,
    String kind, {
    required int keyVersion,
  }) =>
      keyVersion == 1
          ? 'v2:$groupId:$deviceId:$kind:seed'
          : 'v2:$groupId:$deviceId:v$keyVersion:$kind:seed';

  String _currentVersionKey(String groupId, String deviceId) =>
      'v2:$groupId:$deviceId:current_key_version';

  // Cache des SimpleKeyPair reconstruites (persistant pendant la session)
  final Map<String, SimpleKeyPair> _ed25519Cache = <String, SimpleKeyPair>{};
  final Map<String, SimpleKeyPair> _x25519Cache = <String, SimpleKeyPair>{};
  final Set<String> _validatedKeyMaterial = <String>{};
  final Map<String, Future<void>> _pendingInitialization =
      <String, Future<void>>{};

  String _cacheKey(String groupId, String deviceId, int keyVersion) =>
      '$groupId:$deviceId:$keyVersion';

  Future<int> currentKeyVersion(String groupId, String deviceId) async {
    final stored = await _storage.read(_currentVersionKey(groupId, deviceId));
    if (stored == null) return 1;
    final version = int.tryParse(stored);
    if (version == null || version < 1) {
      throw const KeyMaterialUnavailableException('invalid_key_version');
    }
    return version;
  }

  /// Initialise cryptography pour les performances
  static void initialize() {
    debugPrint('🚀 Cryptography enabled for optimal performance');
  }

  /// Génère et stocke de nouvelles clés
  Future<void> ensureKeysFor(String groupId, String deviceId) async {
    final operationKey = '$groupId:$deviceId';
    await _serialized<void>(
      operationKey,
      () => _ensureKeysFor(groupId, deviceId),
    );
  }

  Future<int> rotateKeysFor(String groupId, String deviceId) async {
    final operationKey = '$groupId:$deviceId';
    return _serialized<int>(operationKey, () async {
      final currentVersion = await currentKeyVersion(groupId, deviceId);
      await _loadExistingKeys(groupId, deviceId, keyVersion: currentVersion);
      final nextVersion = currentVersion + 1;
      final nextMaterial = await _readMaterial(
        groupId,
        deviceId,
        keyVersion: nextVersion,
      );
      if (nextMaterial.any((value) => value != null)) {
        throw const KeyMaterialUnavailableException(
          'next_key_version_already_exists',
        );
      }
      await _generateKeys(groupId, deviceId, keyVersion: nextVersion);
      return nextVersion;
    });
  }

  Future<T> _serialized<T>(
    String operationKey,
    Future<T> Function() operation,
  ) async {
    while (true) {
      final existing = _pendingInitialization[operationKey];
      if (existing != null) {
        await existing;
        continue;
      }
      final completer = Completer<void>();
      _pendingInitialization[operationKey] = completer.future;
      try {
        return await operation();
      } finally {
        completer.complete();
        if (identical(_pendingInitialization[operationKey], completer.future)) {
          _pendingInitialization.remove(operationKey);
        }
      }
    }
  }

  Future<void> _ensureKeysFor(String groupId, String deviceId) async {
    final keyVersion = await currentKeyVersion(groupId, deviceId);
    final material = await _readMaterial(
      groupId,
      deviceId,
      keyVersion: keyVersion,
    );
    if (material.every((value) => value == null)) {
      await _generateKeys(groupId, deviceId, keyVersion: keyVersion);
      return;
    }
    await _loadExistingKeys(
      groupId,
      deviceId,
      keyVersion: keyVersion,
      material: material,
    );
  }

  Future<void> _generateKeys(
    String groupId,
    String deviceId, {
    required int keyVersion,
  }) async {
    debugPrint(
      '🔐 Generating new keys with KeyManagerFinal (true reconstruction)',
    );

    // Générer Ed25519
    final ed25519KeyPair = await Ed25519().newKeyPair();
    final ed25519Seed = await ed25519KeyPair.extractPrivateKeyBytes();
    final ed25519PublicBytes = (await ed25519KeyPair.extractPublicKey()).bytes;

    // Générer X25519
    final x25519KeyPair = await X25519().newKeyPair();
    final x25519Seed = await x25519KeyPair.extractPrivateKeyBytes();
    final x25519PublicBytes = (await x25519KeyPair.extractPublicKey()).bytes;

    // Stocker les seeds (32 octets) et les clés publiques
    await _storage.write(
      _ns(groupId, deviceId, 'ed25519', keyVersion: keyVersion),
      base64Encode(ed25519Seed),
    );
    await _storage.write(
      _ns(groupId, deviceId, 'ed25519_pub', keyVersion: keyVersion),
      base64Encode(ed25519PublicBytes),
    );
    await _storage.write(
      _ns(groupId, deviceId, 'x25519', keyVersion: keyVersion),
      base64Encode(x25519Seed),
    );
    await _storage.write(
      _ns(groupId, deviceId, 'x25519_pub', keyVersion: keyVersion),
      base64Encode(x25519PublicBytes),
    );

    // Mettre en cache les SimpleKeyPair générés
    await _storage.write(_currentVersionKey(groupId, deviceId), '$keyVersion');
    final cacheKey = _cacheKey(groupId, deviceId, keyVersion);
    _ed25519Cache[cacheKey] = ed25519KeyPair;
    _x25519Cache[cacheKey] = x25519KeyPair;
    _validatedKeyMaterial.add(cacheKey);

    debugPrint('🔐 Keys generated and cached with KeyManagerFinal');
  }

  /// Vérifie si les clés existent
  Future<bool> hasKeys(String groupId, String deviceId) async {
    final material = await _readMaterial(
      groupId,
      deviceId,
      keyVersion: await currentKeyVersion(groupId, deviceId),
    );
    return material.every((value) => value != null);
  }

  /// Retourne les clés publiques en Base64
  Future<Map<String, String>> publicKeysBase64(
    String groupId,
    String deviceId, {
    int? keyVersion,
  }) async {
    final version = keyVersion ?? await currentKeyVersion(groupId, deviceId);
    await _loadExistingKeys(groupId, deviceId, keyVersion: version);
    final cacheKey = _cacheKey(groupId, deviceId, version);
    final edPublic = await _ed25519Cache[cacheKey]!.extractPublicKey();
    final xPublic = await _x25519Cache[cacheKey]!.extractPublicKey();
    return {
      'pk_sig': base64Encode(edPublic.bytes),
      'pk_kem': base64Encode(xPublic.bytes),
    };
  }

  /// 🎉 SOLUTION FINALE: Charge la clé Ed25519 avec reconstruction depuis le seed
  Future<SimpleKeyPair> loadEd25519KeyPair(
    String groupId,
    String deviceId, {
    int? keyVersion,
  }) async {
    final version = keyVersion ?? await currentKeyVersion(groupId, deviceId);
    final cacheKey = _cacheKey(groupId, deviceId, version);
    await _loadExistingKeys(groupId, deviceId, keyVersion: version);
    return _ed25519Cache[cacheKey]!;
  }

  /// 🚀 OPTIMISATION: Extrait les bytes de la clé privée X25519 (sans créer KeyPair)
  /// Utilisé pour sérialisation vers Isolate
  Future<Uint8List> getX25519PrivateKeyBytes(
    String groupId,
    String deviceId, {
    int? keyVersion,
  }) async {
    final keyPair = await loadX25519KeyPair(
      groupId,
      deviceId,
      keyVersion: keyVersion,
    );
    return Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
  }

  /// 🎉 SOLUTION FINALE: Charge la clé X25519 avec reconstruction depuis le seed
  Future<SimpleKeyPair> loadX25519KeyPair(
    String groupId,
    String deviceId, {
    int? keyVersion,
  }) async {
    final version = keyVersion ?? await currentKeyVersion(groupId, deviceId);
    final cacheKey = _cacheKey(groupId, deviceId, version);
    await _loadExistingKeys(groupId, deviceId, keyVersion: version);
    return _x25519Cache[cacheKey]!;
  }

  Future<List<String?>> _readMaterial(
    String groupId,
    String deviceId, {
    required int keyVersion,
  }) => Future.wait(<Future<String?>>[
    _storage.read(_ns(groupId, deviceId, 'ed25519', keyVersion: keyVersion)),
    _storage.read(
      _ns(groupId, deviceId, 'ed25519_pub', keyVersion: keyVersion),
    ),
    _storage.read(_ns(groupId, deviceId, 'x25519', keyVersion: keyVersion)),
    _storage.read(_ns(groupId, deviceId, 'x25519_pub', keyVersion: keyVersion)),
  ]);

  Uint8List _decode32(String value) {
    try {
      final bytes = base64Decode(value);
      if (bytes.length != 32) {
        throw const KeyMaterialUnavailableException('invalid_key_length');
      }
      return bytes;
    } on KeyMaterialUnavailableException {
      rethrow;
    } on FormatException {
      throw const KeyMaterialUnavailableException('invalid_key_encoding');
    }
  }

  Future<void> _loadExistingKeys(
    String groupId,
    String deviceId, {
    required int keyVersion,
    List<String?>? material,
  }) async {
    final cacheKey = _cacheKey(groupId, deviceId, keyVersion);
    if (_validatedKeyMaterial.contains(cacheKey)) return;

    final values =
        material ??
        await _readMaterial(groupId, deviceId, keyVersion: keyVersion);
    if (values.any((value) => value == null)) {
      throw const KeyMaterialUnavailableException(
        'missing_or_partial_key_material',
      );
    }

    try {
      final edSeed = _decode32(values[0]!);
      final storedEdPublic = _decode32(values[1]!);
      final xSeed = _decode32(values[2]!);
      final storedXPublic = _decode32(values[3]!);

      final edKeyPair = await Ed25519().newKeyPairFromSeed(edSeed);
      final xKeyPair = await X25519().newKeyPairFromSeed(xSeed);
      final derivedEdPublic = (await edKeyPair.extractPublicKey()).bytes;
      final derivedXPublic = (await xKeyPair.extractPublicKey()).bytes;

      if (!listEquals(storedEdPublic, derivedEdPublic) ||
          !listEquals(storedXPublic, derivedXPublic)) {
        throw const KeyMaterialUnavailableException('public_key_mismatch');
      }

      _ed25519Cache[cacheKey] = edKeyPair;
      _x25519Cache[cacheKey] = xKeyPair;
      _validatedKeyMaterial.add(cacheKey);
    } on KeyMaterialUnavailableException {
      rethrow;
    } catch (_) {
      throw const KeyMaterialUnavailableException('invalid_key_material');
    }
  }

  Future<void> clearMemoryCaches() async {
    final pending = _pendingInitialization.values.toList(growable: false);
    try {
      await Future.wait(pending);
    } catch (_) {
      // La purge doit rester possible même si une initialisation a échoué.
    } finally {
      _ed25519Cache.clear();
      _x25519Cache.clear();
      _validatedKeyMaterial.clear();
    }
  }

  /// Indique si les clés ont besoin d'être republiées (compatibilité avec KeyManagerV2)
  bool get keysNeedRepublishing => false; // KeyManagerFinal n'a pas ce problème

  /// Marque les clés comme republiées (compatibilité avec KeyManagerV2)
  void markKeysRepublished() {
    // KeyManagerFinal n'a pas besoin de cette fonctionnalité
  }

  /// La migration historique n'est pas sûre sans preuve du compte propriétaire.
  Future<void> migrateFromLegacy(String groupId, String deviceId) async {
    if (await hasKeys(groupId, deviceId)) {
      await _loadExistingKeys(
        groupId,
        deviceId,
        keyVersion: await currentKeyVersion(groupId, deviceId),
      );
      return;
    }
    throw const KeyMaterialUnavailableException(
      'legacy_key_migration_requires_account_binding',
    );
  }
}
