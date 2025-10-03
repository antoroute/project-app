import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class SessionDeviceService {
  SessionDeviceService._internal();
  static final SessionDeviceService instance = SessionDeviceService._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const String _deviceIdKey = 'device_id_v1';
  String? _cachedDeviceId;

  Future<String> getOrCreateDeviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      _cachedDeviceId = existing;
      return existing;
    }
    final String newId = const Uuid().v4();
    await _storage.write(key: _deviceIdKey, value: newId);
    _cachedDeviceId = newId;
    return newId;
  }
}


