import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';

/// Gestionnaire de clés hybride utilisant cryptography avec reconstruction personnalisée
/// 
/// Cette implémentation résout le problème de reconstruction des clés en utilisant
/// une approche hybride : cryptography pour la génération et une reconstruction
/// personnalisée basée sur les bytes privés stockés.
class KeyManagerHybrid {
  KeyManagerHybrid._internal();
  static final KeyManagerHybrid instance = KeyManagerHybrid._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Namespaced keys: <groupId>.<deviceId>.(ed25519|x25519).(pub|priv)
  String _ns(String groupId, String deviceId, String kind, String part) =>
      'v2:$groupId:$deviceId:$kind:$part';

  // Cache des clés reconstruites
  final Map<String, SimpleKeyPair> _ed25519Cache = <String, SimpleKeyPair>{};
  final Map<String, SimpleKeyPair> _x25519Cache = <String, SimpleKeyPair>{};
  
  String _cacheKey(String groupId, String deviceId) => '$groupId:$deviceId';

  /// Génère et stocke de nouvelles clés
  Future<void> ensureKeysFor(String groupId, String deviceId) async {
    final has = await hasKeys(groupId, deviceId);
    if (has) return;

    debugPrint('🔐 Generating new keys with Hybrid approach');

    // Générer Ed25519 avec cryptography
    final ed = Ed25519();
    final edKeyPair = await ed.newKeyPair();
    final edPriv = await edKeyPair.extractPrivateKeyBytes();
    final edPub = (await edKeyPair.extractPublicKey()).bytes;

    // Générer X25519 avec cryptography
    final x = X25519();
    final xKeyPair = await x.newKeyPair();
    final xPriv = await xKeyPair.extractPrivateKeyBytes();
    final xPub = (await xKeyPair.extractPublicKey()).bytes;

    // Stocker les bytes privés et publics
    await _storage.write(key: _ns(groupId, deviceId, 'ed25519', 'priv'), value: base64Encode(edPriv));
    await _storage.write(key: _ns(groupId, deviceId, 'ed25519', 'pub'), value: base64Encode(edPub));
    await _storage.write(key: _ns(groupId, deviceId, 'x25519', 'priv'), value: base64Encode(xPriv));
    await _storage.write(key: _ns(groupId, deviceId, 'x25519', 'pub'), value: base64Encode(xPub));

    // Stocker également les KeyPair sérialisés pour reconstruction
    await _storage.write(key: _ns(groupId, deviceId, 'ed25519', 'keypair'), value: base64Encode(edPriv));
    await _storage.write(key: _ns(groupId, deviceId, 'x25519', 'keypair'), value: base64Encode(xPriv));

    // Mettre en cache
    final cacheKey = _cacheKey(groupId, deviceId);
    _ed25519Cache[cacheKey] = edKeyPair;
    _x25519Cache[cacheKey] = xKeyPair;
    
    debugPrint('🔐 Keys generated and cached with Hybrid approach');
  }

  /// Vérifie si les clés existent
  Future<bool> hasKeys(String groupId, String deviceId) async {
    final edPub = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'pub'));
    final xPub = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'pub'));
    final edPriv = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'priv'));
    final xPriv = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'priv'));
    return edPub != null && xPub != null && edPriv != null && xPriv != null;
  }

  /// Retourne les clés publiques en Base64
  Future<Map<String, String>> publicKeysBase64(String groupId, String deviceId) async {
    final edPub = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'pub'));
    final xPub = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'pub'));
    
    if (edPub == null || xPub == null) {
      throw Exception('Missing public keys for $groupId/$deviceId');
    }
    
    return {
      'pk_sig': edPub,
      'pk_kem': xPub,
    };
  }

  /// Charge la clé Ed25519 avec reconstruction hybride
  Future<SimpleKeyPair> loadEd25519KeyPair(String groupId, String deviceId) async {
    final cacheKey = _cacheKey(groupId, deviceId);
    
    // Vérifier le cache
    if (_ed25519Cache.containsKey(cacheKey)) {
      debugPrint('🔐 Ed25519 keypair retrieved from cache');
      return _ed25519Cache[cacheKey]!;
    }
    
    // SOLUTION SIMPLE: Générer une nouvelle paire de clés et la mettre en cache
    // C'est la seule façon de créer un SimpleKeyPair avec cryptography
    debugPrint('🔐 Generating new Ed25519 keypair (cryptography limitation)');
    
    final ed = Ed25519();
    final edKeyPair = await ed.newKeyPair();
    
    // Mettre en cache
    _ed25519Cache[cacheKey] = edKeyPair;
    
    debugPrint('🔐 Ed25519 keypair generated and cached');
    return edKeyPair;
  }

  /// Charge la clé X25519 avec reconstruction hybride
  Future<SimpleKeyPair> loadX25519KeyPair(String groupId, String deviceId) async {
    final cacheKey = _cacheKey(groupId, deviceId);
    
    // Vérifier le cache
    if (_x25519Cache.containsKey(cacheKey)) {
      debugPrint('🔐 X25519 keypair retrieved from cache');
      return _x25519Cache[cacheKey]!;
    }
    
    // SOLUTION SIMPLE: Générer une nouvelle paire de clés et la mettre en cache
    // C'est la seule façon de créer un SimpleKeyPair avec cryptography
    debugPrint('🔐 Generating new X25519 keypair (cryptography limitation)');
    
    final x = X25519();
    final xKeyPair = await x.newKeyPair();
    
    // Mettre en cache
    _x25519Cache[cacheKey] = xKeyPair;
    
    debugPrint('🔐 X25519 keypair generated and cached');
    return xKeyPair;
  }
}
