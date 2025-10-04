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

  // Cache persistant des KeyPair en mémoire pour garantir la cohérence 
  final Map<String, SimpleKeyPair> _ed25519Cache = <String, SimpleKeyPair>{};
  final Map<String, SimpleKeyPair> _x25519Cache = <String, SimpleKeyPair>{};
  
  // Flag pour savoir si les clés ont été chargées depuis le stockage
  final Set<String> _loadedFromStorage = <String>{};
  
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
    
    // If we've never loaded from storage for this group/device, ensure keys exist
    if (!_loadedFromStorage.contains(cacheKey)) {
      debugPrint('📦 First access to Ed25519 keys for $groupId/$deviceId - ensuring they exist');
      await ensureKeysFor(groupId, deviceId);
      _loadedFromStorage.add(cacheKey);
      
      // Should now be in cache
      if (_ed25519Cache.containsKey(cacheKey)) {
        debugPrint('✅ Ed25519 keypair loaded from initial generation');
        return _ed25519Cache[cacheKey]!;
      }
    }
    
    throw Exception('Failed to access Ed25519 keypair for $groupId/$deviceId');
  }

  Future<SimpleKeyPair> loadX25519KeyPair(String groupId, String deviceId) async {
    final cacheKey = _cacheKey(groupId, deviceId);
    
    // Check memory cache first
    if (_x25519Cache.containsKey(cacheKey)) {
      debugPrint('🔐 X25519 keypair retrieved from memory cache');
      return _x25519Cache[cacheKey]!;
    }
    
    // If we've never loaded from storage for this group/device, ensure keys exist
    if (!_loadedFromStorage.contains(cacheKey)) {
      debugPrint('📦 First access to X25519 keys for $groupId/$deviceId - ensuring they exist');
      await ensureKeysFor(groupId, deviceId);
      _loadedFromStorage.add(cacheKey);
      
      // Should now be in cache
      if (_x25519Cache.containsKey(cacheKey)) {
        debugPrint('✅ X25519 keypair loaded from initial generation');
        return _x25519Cache[cacheKey]!;
      }
    }
    
    throw Exception('Failed to access X25519 keypair for $groupId/$deviceId');
  }

}


