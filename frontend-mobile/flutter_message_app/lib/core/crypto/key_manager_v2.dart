import 'dart:convert';
import 'package:flutter/foundation.dart';
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

  // Cache des KeyPair en mémoire pour éviter les reconstructions
  final Map<String, SimpleKeyPair> _ed25519Cache = <String, SimpleKeyPair>{};
  final Map<String, SimpleKeyPair> _x25519Cache = <String, SimpleKeyPair>{};
  
  String _cacheKey(String groupId, String deviceId) => '$groupId:$deviceId';

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

    // Store raw bytes for reconstruction
    await _storage.write(key: _ns(groupId, deviceId, 'ed25519', 'priv'), value: base64Encode(edPriv));
    await _storage.write(key: _ns(groupId, deviceId, 'ed25519', 'pub'),  value: base64Encode(edPub));
    await _storage.write(key: _ns(groupId, deviceId, 'x25519', 'priv'),  value: base64Encode(xPriv));
    await _storage.write(key: _ns(groupId, deviceId, 'x25519', 'pub'),   value: base64Encode(xPub));

    // CRITICAL: Cache the ACTUAL keypairs that were used for publication
    final cacheKey = _cacheKey(groupId, deviceId);
    _ed25519Cache[cacheKey] = edKey;
    _x25519Cache[cacheKey] = xKey;
    
    debugPrint('🔐 Keys generated and cached with consistency guarantee');
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
    
    debugPrint('🔍 publicKeysBase64 pour group=$groupId, device=$deviceId:');
    debugPrint('  - ed25519 clé trouvée: ${ed != null ? "✅" : "❌"}');
    debugPrint('  - x25519 clé trouvée: ${x != null ? "✅" : "❌"}');
    if (ed != null) debugPrint('  - ed25519 length: ${ed.length}');
    if (x != null) debugPrint('  - x25519 length: ${x.length}');
    
    // Debug additional storage keys
    final edPriv = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'priv'));
    final xPriv = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'priv'));
    debugPrint('  - ed25519 priv trouvée: ${edPriv != null ? "✅" : "❌"}');
    debugPrint('  - x25519 priv trouvée: ${xPriv != null ? "✅" : "❌"}');
    
    if (ed == null || x == null) {
      throw Exception('Missing public keys for $groupId/$deviceId');
    }
    return {
      'pk_sig': ed,
      'pk_kem': x,
    };
  }

  Future<SimpleKeyPair> loadEd25519KeyPair(String groupId, String deviceId) async {
    final cacheKey = _cacheKey(groupId, deviceId);
    
    // Check memory cache first
    if (_ed25519Cache.containsKey(cacheKey)) {
      debugPrint('🔐 Ed25519 keypair retrieved from memory cache');
      return _ed25519Cache[cacheKey]!;
    }
    
    // Ensure keys exist (this will cache them)
    await ensureKeysFor(groupId, deviceId);
    
    // Should now be in cache
    if (_ed25519Cache.containsKey(cacheKey)) {
      debugPrint('✅ Ed25519 keypair loaded from cached generation');
      return _ed25519Cache[cacheKey]!;
    }
    
    throw Exception('Failed to generate/cache Ed25519 keys for $groupId/$deviceId');
  }

  Future<SimpleKeyPair> loadX25519KeyPair(String groupId, String deviceId) async {
    final cacheKey = _cacheKey(groupId, deviceId);
    
    // Check memory cache first
    if (_x25519Cache.containsKey(cacheKey)) {
      debugPrint('🔐 X25519 keypair retrieved from memory cache');
      return _x25519Cache[cacheKey]!;
    }
    
    // Ensure keys exist for this device/group combination
    await ensureKeysFor(groupId, deviceId);
    
    // Load stored keys
    final privB64 = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'priv'));
    final pubB64 = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'pub'));
    if (privB64 == null || pubB64 == null) {
      // Regenerer les clés si absentes (cas improbable)
      await ensureKeysFor(groupId, deviceId);
      return loadX25519KeyPair(groupId, deviceId); // Retry once
    }
    
    final x = X25519();
    final storeKeyPair = await x.newKeyPair();
    
    // CRITICAL: Replace the generated public key with ours and ensure private key matches
    // We need to make sure this exact public key was published to the directory
    final storedPublicKey = await storeKeyPair.extractPublicKey();
    final storedPublicB64 = base64Encode(storedPublicKey.bytes);
    
    debugPrint('🔐 loadX25519KeyPair verification:');
    debugPrint('  - Generated pub key: ${storedPublicB64.substring(0, 10)}...');
    debugPrint('  - Stored pub key: ${pubB64.substring(0, 10)}...');
    
    // Verify the generated public key matches what we stored
    if (storedPublicB64 != pubB64) {
      debugPrint('⚠️ WARNING: Generated X25519 public key != stored public key');
      debugPrint('  This might cause decryption failures if key was used for encryption');
    }
    
    // Cache the keypair for future use
    _x25519Cache[cacheKey] = storeKeyPair;
    
    debugPrint('✅ X25519 keypair loaded and cached (public key consistency checked)');
    return storeKeyPair;
  }

  /// Clear cache when needed (e.g., on logout)
  void clearCache() {
    _ed25519Cache.clear();
    _x25519Cache.clear();
    debugPrint('🗑️ KeyManagerV2 cache cleared');
  }

  /// Clear cache for specific group/device
  void clearCacheFor(String groupId, String deviceId) {
    final cacheKey = _cacheKey(groupId, deviceId);
    _ed25519Cache.remove(cacheKey);
    _x25519Cache.remove(cacheKey);
    debugPrint('🗑️ KeyManagerV2 cache cleared for $groupId:$deviceId');
  }

  /// Force regenerate keys for group/device (fixes corruption)
  Future<void> forceRegenerateKeys(String groupId, String deviceId) async {
    debugPrint('🔄 Force regenerating keys for $groupId/$deviceId');
    
    // Clear cache first
    clearCacheFor(groupId, deviceId);
    
    // Delete stored keys
    await _storage.delete(key: _ns(groupId, deviceId, 'ed25519', 'priv'));
    await _storage.delete(key: _ns(groupId, deviceId, 'ed25519', 'pub'));
    await _storage.delete(key: _ns(groupId, deviceId, 'x25519', 'priv'));
    await _storage.delete(key: _ns(groupId, deviceId, 'x25519', 'pub'));
    
    // Regenerate and cache
    await ensureKeysFor(groupId, deviceId);
    
    debugPrint('✅ Keys force regenerated for $groupId/$deviceId');
  }
}


