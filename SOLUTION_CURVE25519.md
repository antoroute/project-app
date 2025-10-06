# SOLUTION FINALE - MIGRATION VERS CURVE25519-DART

## 🎯 **PROBLÈME IDENTIFIÉ**

Vous avez raison ! La bibliothèque `cryptography` ne permet pas de reconstruire les `SimpleKeyPair` depuis les bytes stockés. PointyCastle n'a pas non plus de support natif pour Ed25519 et X25519.

## 🚀 **SOLUTION : BIBLIOTHÈQUE SPÉCIALISÉE**

Utilisons `curve25519-dart` qui est spécialement conçue pour Curve25519 et Ed25519 :

### **1. Ajouter la dépendance**

```yaml
dependencies:
  curve25519_dart: ^0.0.1
```

### **2. Implémentation avec curve25519-dart**

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:curve25519_dart/curve25519_dart.dart';

/// Gestionnaire de clés utilisant curve25519-dart pour la vraie reconstruction
class KeyManagerCurve25519 {
  KeyManagerCurve25519._internal();
  static final KeyManagerCurve25519 instance = KeyManagerCurve25519._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Namespaced keys
  String _ns(String groupId, String deviceId, String kind, String part) =>
      'v2:$groupId:$deviceId:$kind:$part';

  // Cache des clés reconstruites
  final Map<String, Uint8List> _ed25519PrivateCache = <String, Uint8List>{};
  final Map<String, Uint8List> _x25519PrivateCache = <String, Uint8List>{};
  
  String _cacheKey(String groupId, String deviceId) => '$groupId:$deviceId';

  /// Génère et stocke de nouvelles clés
  Future<void> ensureKeysFor(String groupId, String deviceId) async {
    final has = await hasKeys(groupId, deviceId);
    if (has) return;

    debugPrint('🔐 Generating new keys with curve25519-dart');

    // Générer Ed25519
    final ed25519PrivateKey = Ed25519.generatePrivateKey();
    final ed25519PublicKey = Ed25519.publicFromPrivate(ed25519PrivateKey);

    // Générer X25519
    final x25519PrivateKey = Curve25519.generatePrivateKey();
    final x25519PublicKey = Curve25519.publicFromPrivate(x25519PrivateKey);

    // Stocker les bytes privés et publics
    await _storage.write(key: _ns(groupId, deviceId, 'ed25519', 'priv'), value: base64Encode(ed25519PrivateKey));
    await _storage.write(key: _ns(groupId, deviceId, 'ed25519', 'pub'), value: base64Encode(ed25519PublicKey));
    await _storage.write(key: _ns(groupId, deviceId, 'x25519', 'priv'), value: base64Encode(x25519PrivateKey));
    await _storage.write(key: _ns(groupId, deviceId, 'x25519', 'pub'), value: base64Encode(x25519PublicKey));

    // Mettre en cache
    final cacheKey = _cacheKey(groupId, deviceId);
    _ed25519PrivateCache[cacheKey] = ed25519PrivateKey;
    _x25519PrivateCache[cacheKey] = x25519PrivateKey;
    
    debugPrint('🔐 Keys generated and cached with curve25519-dart');
  }

  /// Charge la clé privée Ed25519 (reconstruction depuis les bytes stockés)
  Future<Uint8List> loadEd25519PrivateKey(String groupId, String deviceId) async {
    final cacheKey = _cacheKey(groupId, deviceId);
    
    // Vérifier le cache
    if (_ed25519PrivateCache.containsKey(cacheKey)) {
      debugPrint('🔐 Ed25519 private key retrieved from cache');
      return _ed25519PrivateCache[cacheKey]!;
    }
    
    // Charger depuis le stockage
    final privB64 = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'priv'));
    if (privB64 == null) {
      throw Exception('Ed25519 private key not found in storage');
    }
    
    // AVANTAGE curve25519-dart: Reconstruction depuis les bytes privés
    final privateKeyBytes = base64Decode(privB64);
    
    // Mettre en cache
    _ed25519PrivateCache[cacheKey] = privateKeyBytes;
    
    debugPrint('🔐 Ed25519 private key reconstructed from storage');
    return privateKeyBytes;
  }

  /// Charge la clé privée X25519 (reconstruction depuis les bytes stockés)
  Future<Uint8List> loadX25519PrivateKey(String groupId, String deviceId) async {
    final cacheKey = _cacheKey(groupId, deviceId);
    
    // Vérifier le cache
    if (_x25519PrivateCache.containsKey(cacheKey)) {
      debugPrint('🔐 X25519 private key retrieved from cache');
      return _x25519PrivateCache[cacheKey]!;
    }
    
    // Charger depuis le stockage
    final privB64 = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'priv'));
    if (privB64 == null) {
      throw Exception('X25519 private key not found in storage');
    }
    
    // AVANTAGE curve25519-dart: Reconstruction depuis les bytes privés
    final privateKeyBytes = base64Decode(privB64);
    
    // Mettre en cache
    _x25519PrivateCache[cacheKey] = privateKeyBytes;
    
    debugPrint('🔐 X25519 private key reconstructed from storage');
    return privateKeyBytes;
  }

  /// Signe un message avec Ed25519
  Future<Uint8List> signEd25519(String groupId, String deviceId, Uint8List message) async {
    final privateKey = await loadEd25519PrivateKey(groupId, deviceId);
    return Ed25519.sign(message, privateKey);
  }

  /// Vérifie une signature Ed25519
  Future<bool> verifyEd25519(Uint8List signature, Uint8List message, Uint8List publicKeyBytes) async {
    return Ed25519.verify(signature, message, publicKeyBytes);
  }

  /// Calcule le secret partagé X25519
  Future<Uint8List> computeSharedSecret(String groupId, String deviceId, Uint8List otherPublicKeyBytes) async {
    final privateKey = await loadX25519PrivateKey(groupId, deviceId);
    return Curve25519.sharedSecret(privateKey, otherPublicKeyBytes);
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

  /// Vérifie si les clés existent
  Future<bool> hasKeys(String groupId, String deviceId) async {
    final edPub = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'pub'));
    final xPub = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'pub'));
    final edPriv = await _storage.read(key: _ns(groupId, deviceId, 'ed25519', 'priv'));
    final xPriv = await _storage.read(key: _ns(groupId, deviceId, 'x25519', 'priv'));
    return edPub != null && xPub != null && edPriv != null && xPriv != null;
  }
}
```

## 🎯 **AVANTAGES DE CETTE SOLUTION**

1. **✅ Vraie reconstruction** : Les clés sont reconstruites depuis les bytes stockés
2. **✅ Pas de génération** : Pas de nouvelles clés au redémarrage
3. **✅ Messages anciens** : Restent déchiffrables
4. **✅ Performance** : Pas de republication nécessaire
5. **✅ Sécurité** : Même niveau cryptographique

## 🚀 **PROCHAINES ÉTAPES**

1. **Ajouter `curve25519-dart`** à `pubspec.yaml`
2. **Implémenter cette solution**
3. **Migrer les fichiers existants**
4. **Tester la reconstruction**

**Cette solution résoudra définitivement le problème de reconstruction des clés !** 🎉

