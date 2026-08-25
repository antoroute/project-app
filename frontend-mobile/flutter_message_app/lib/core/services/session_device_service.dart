import 'package:uuid/uuid.dart';

import 'secure_string_store.dart';

class SessionDeviceService {
  SessionDeviceService._internal({
    SecureStringStore? storage,
    String Function()? generateDeviceId,
  }) : _storage = storage ?? PlatformSecureStringStore(),
       _generateDeviceId = generateDeviceId ?? const Uuid().v4;

  static final SessionDeviceService instance = SessionDeviceService._internal();

  factory SessionDeviceService.forTesting({
    required SecureStringStore storage,
    required String Function() generateDeviceId,
  }) => SessionDeviceService._internal(
    storage: storage,
    generateDeviceId: generateDeviceId,
  );

  final SecureStringStore _storage;
  final String Function() _generateDeviceId;

  static final RegExp _userIdPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  final Map<String, String> _cachedDeviceIds = <String, String>{};
  final Map<String, Future<String>> _pendingDeviceIds =
      <String, Future<String>>{};

  String _deviceIdKey(String userId) => 'device_id_v2:account:$userId';

  /// Charge un identifiant existant sans jamais en créer un implicitement.
  Future<String?> loadDeviceId(String userId) async {
    if (!_userIdPattern.hasMatch(userId)) {
      throw ArgumentError.value(userId, 'userId', 'invalid account identifier');
    }
    final cached = _cachedDeviceIds[userId];
    if (cached != null) return cached;

    final existing = await _storage.read(_deviceIdKey(userId));
    if (existing == null) return null;
    if (!_userIdPattern.hasMatch(existing)) {
      throw StateError('stored device identifier is invalid');
    }
    _cachedDeviceIds[userId] = existing;
    return existing;
  }

  Future<String> getOrCreateDeviceId(String userId) async {
    if (!_userIdPattern.hasMatch(userId)) {
      throw ArgumentError.value(userId, 'userId', 'invalid account identifier');
    }
    final cached = _cachedDeviceIds[userId];
    if (cached != null) return cached;

    final pending = _pendingDeviceIds[userId];
    if (pending != null) return pending;

    final resolution = _loadOrCreateDeviceId(userId);
    _pendingDeviceIds[userId] = resolution;
    try {
      return await resolution;
    } finally {
      if (identical(_pendingDeviceIds[userId], resolution)) {
        _pendingDeviceIds.remove(userId);
      }
    }
  }

  Future<String> _loadOrCreateDeviceId(String userId) async {
    final existing = await _storage.read(_deviceIdKey(userId));
    if (existing != null) {
      if (!_userIdPattern.hasMatch(existing)) {
        throw StateError('stored device identifier is invalid');
      }
      _cachedDeviceIds[userId] = existing;
      return existing;
    }

    final newId = _generateDeviceId();
    if (!_userIdPattern.hasMatch(newId)) {
      throw StateError('device identifier generator returned an invalid UUID');
    }
    await _storage.write(_deviceIdKey(userId), newId);
    _cachedDeviceIds[userId] = newId;
    return newId;
  }

  Future<void> clearMemoryCache() async {
    final pending = _pendingDeviceIds.values.toList(growable: false);
    try {
      await Future.wait(pending);
    } catch (_) {
      // La purge doit rester possible même si une initialisation a échoué.
    } finally {
      _cachedDeviceIds.clear();
    }
  }
}
