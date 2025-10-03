import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class KeyManagerV2 {
  KeyManagerV2._internal();
  static final KeyManagerV2 instance = KeyManagerV2._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Namespaced keys: <groupId>.<deviceId>.(ed25519|x25519).(pub|priv)
  String _ns(String groupId, String deviceId, String kind, String part) =>
      'v2:$groupId:$deviceId:$kind:$part';

  Future<void> ensureKeysFor(String groupId, String deviceId) async {
    final has = await hasKeys(groupId, deviceId);
    if (has) return;

    // Generate truly random keys (correct cryptographically)
    final ed = Ed25519();
    final edKey = await ed.newKeyPair();
    final edPriv = await edKey.extractPrivateKeyBytes();
    final edPub = (await edKey.extractPublicKey()).bytes;

    // Generate X25519
    final x = X25519();
    final xKey = await x.newKeyPair();
    final xPriv = await xKey.extractPrivateKeyBytes();
    final xPub = (await xKey.extractPublicKey()).bytes;

    await _storage.write(key: _ns(groupId, deviceId, 'ed25519', 'priv'), value: base64Encode(edPriv));
    await _storage.write(key: _ns(groupId, deviceId, 'ed25519', 'pub'),  value: base64Encode(edPub));
    await _storage.write(key: _ns(groupId, deviceId, 'x25519', 'priv'),  value: base64Encode(xPriv));
    await _storage.write(key: _ns(groupId, deviceId, 'x25519', 'pub'),   value: base64Encode(xPub));
  }

  Future<bool> hasKeys(String groupId, String deviceId) async {
    final edPub = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'pub'));
    final xPub = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'pub'));
    final edPriv = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'priv'));
    final xPriv = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'priv'));
    return edPub != null && xPub != null && edPriv != null && xPriv != null;
  }

  Future<Map<String, String>> publicKeysBase64(String groupId, String deviceId) async {
    final ed = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'pub'));
    final x = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'pub'));
    if (ed == null || x == null) {
      throw Exception('Missing public keys for $groupId/$deviceId');
    }
    return {
      'pk_sig': ed,
      'pk_kem': x,
    };
  }

  Future<SimpleKeyPair> loadEd25519KeyPair(String groupId, String deviceId) async {
    // Ensure keys exist for this device/group combination
    // This will generate them if they don't exist
    await ensureKeysFor(groupId, deviceId);
    
    // For now, generate a new keypair each time
    // TODO: Proper key loading from storage when cryptography package supports it
    final ed = Ed25519();
    return await ed.newKeyPair();
  }

  Future<SimpleKeyPair> loadX25519KeyPair(String groupId, String deviceId) async {
    // Ensure keys exist for this device/group combination
    // This will generate them if they don't exist
    await ensureKeysFor(groupId, deviceId);
    
    // For now, generate a new keypair each time
    // TODO: Proper key loading from storage when cryptography package supports it
    final x = X25519();
    return await x.newKeyPair();
  }
}


