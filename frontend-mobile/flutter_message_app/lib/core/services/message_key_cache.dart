import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import '../crypto/key_manager_final.dart';
import '../services/key_directory_service.dart';

/// Cache de message keys dérivées pour optimisation du déchiffrement
/// 
/// Inspiré de Signal : pré-dérive les message keys dès réception
/// pour un déchiffrement instantané.
/// 
/// Sécurité :
/// - Cache temporaire en mémoire uniquement (comme Signal)
/// - TTL court pour les clés
/// - Nettoyage automatique
class MessageKeyCache {
  MessageKeyCache._internal();
  static final MessageKeyCache instance = MessageKeyCache._internal();

  /// Cache des message keys dérivées
  /// Clé: messageId, Valeur: message key (32 bytes)
  final Map<String, _CachedMessageKey> _cache = {};
  
  /// Cache des "skipped keys" pour messages hors-ordre
  /// Clé: messageId, Valeur: message key
  final Map<String, _CachedMessageKey> _skippedKeys = {};
  
  static const Duration _defaultTtl = Duration(hours: 24);
  static const int _maxCacheSize = 1000; // Limite de sécurité

  /// Dérive et cache une message key pour un message
  /// 
  /// Cette méthode doit être appelée dès réception d'un message
  /// pour pré-dériver la clé et permettre un déchiffrement instantané.
  Future<Uint8List?> deriveAndCacheMessageKey({
    required String messageId,
    required String groupId,
    required String myUserId,
    required String myDeviceId,
    required Map<String, dynamic> messageV2,
    required KeyDirectoryService keyDirectory,
  }) async {
    try {
      // Vérifier si déjà en cache
      final cached = _cache[messageId];
      if (cached != null && !cached.isExpired) {
        debugPrint('🔑 Message key récupérée depuis le cache: $messageId');
        return cached.key;
      }

      // Dériver la message key
      final messageKey = await _deriveMessageKey(
        groupId: groupId,
        myUserId: myUserId,
        myDeviceId: myDeviceId,
        messageV2: messageV2,
      );

      if (messageKey != null) {
        // Mettre en cache
        _cache[messageId] = _CachedMessageKey(
          key: messageKey,
          timestamp: DateTime.now(),
          ttl: _defaultTtl,
        );
        
        // Nettoyer si nécessaire
        _cleanupIfNeeded();
        
        debugPrint('✅ Message key dérivée et mise en cache: $messageId');
      }

      return messageKey;
    } catch (e) {
      debugPrint('⚠️ Erreur dérivation message key pour $messageId: $e');
      return null;
    }
  }

  /// Dérive la message key depuis les données V2
  Future<Uint8List?> _deriveMessageKey({
    required String groupId,
    required String myUserId,
    required String myDeviceId,
    required Map<String, dynamic> messageV2,
  }) async {
    try {
      // Récupérer l'eph_pub depuis le sender
      final sender = messageV2['sender'] as Map<String, dynamic>?;
      if (sender == null) return null;
      
      final ephPubB64 = sender['eph_pub'] as String?;
      if (ephPubB64 == null || ephPubB64.isEmpty) {
        return null;
      }

      // Calculer le shared secret (X25519)
      final x = X25519();
      final myKey = await KeyManagerFinal.instance.loadX25519KeyPair(groupId, myDeviceId);
      final ephPub = SimplePublicKey(
        base64.decode(ephPubB64.replaceAll(RegExp(r'[\s\n\r]'), '')),
        type: KeyPairType.x25519,
      );
      final shared = await x.sharedSecretKey(
        keyPair: myKey,
        remotePublicKey: ephPub,
      );

      // Récupérer la salt depuis le payload
      if (!messageV2.containsKey('salt')) {
        return null; // Salt requise
      }
      final salt = base64.decode(messageV2['salt'] as String);

      // Dériver KEK avec HKDF
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final infoData = 'project-app/v2 $groupId ${messageV2['convId']} $myUserId $myDeviceId';
      final kek = await hkdf.deriveKey(
        secretKey: shared,
        nonce: salt,
        info: utf8.encode(infoData),
      );
      final kekBytes = Uint8List.fromList(await kek.extractBytes());

      // Récupérer les recipients
      final recipients = messageV2['recipients'] as List<dynamic>?;
      if (recipients == null || recipients.isEmpty) return null;
      
      Map<String, dynamic>? mine;
      for (final r in recipients) {
        final m = r as Map<String, dynamic>;
        if (m['userId'] == myUserId && m['deviceId'] == myDeviceId) {
          mine = m;
          break;
        }
      }
      
      if (mine == null) {
        // Message pas pour nous
        debugPrint('⚠️ Message key non trouvée pour notre device');
        return null;
      }

      // Unwrap la message key
      final aead = AesGcm.with256bits();
      final wrapBytes = base64.decode(mine['wrap'] as String);
      final wrapNonce = base64.decode(mine['nonce'] as String);
      final macLen = 16;
      final cipherLen = wrapBytes.length - macLen;
      
      final wrapBox = SecretBox(
        wrapBytes.sublist(0, cipherLen),
        nonce: wrapNonce,
        mac: Mac(wrapBytes.sublist(cipherLen)),
      );
      
      final mkBytes = await aead.decrypt(
        wrapBox,
        secretKey: SecretKey(kekBytes),
      );

      return Uint8List.fromList(mkBytes);
    } catch (e) {
      debugPrint('❌ Erreur dérivation message key: $e');
      return null;
    }
  }

  /// Récupère une message key depuis le cache
  Uint8List? getMessageKey(String messageId) {
    final cached = _cache[messageId];
    if (cached != null && !cached.isExpired) {
      return cached.key;
    }
    
    // Vérifier aussi les skipped keys
    final skipped = _skippedKeys[messageId];
    if (skipped != null && !skipped.isExpired) {
      return skipped.key;
    }
    
    return null;
  }

  /// Ajoute une message key aux skipped keys (pour messages hors-ordre)
  void addSkippedKey(String messageId, Uint8List key) {
    _skippedKeys[messageId] = _CachedMessageKey(
      key: key,
      timestamp: DateTime.now(),
      ttl: _defaultTtl,
    );
    
    _cleanupSkippedKeys();
    debugPrint('📦 Skipped key ajoutée: $messageId');
  }

  /// Nettoie les clés expirées
  void _cleanupIfNeeded() {
    if (_cache.length <= _maxCacheSize) return;
    
    final expired = <String>[];
    
    for (final entry in _cache.entries) {
      if (entry.value.isExpired) {
        expired.add(entry.key);
      }
    }
    
    for (final key in expired) {
      _cache.remove(key);
    }
    
    // Si toujours trop grand, supprimer les plus anciens
    if (_cache.length > _maxCacheSize) {
      final sorted = _cache.entries.toList()
        ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
      
      final toRemove = sorted.take(_cache.length - _maxCacheSize).map((e) => e.key).toList();
      for (final key in toRemove) {
        _cache.remove(key);
      }
    }
    
    if (expired.isNotEmpty || _cache.length > _maxCacheSize) {
      debugPrint('🧹 Nettoyage cache: ${expired.length} clés expirées, ${_cache.length} clés restantes');
    }
  }

  /// Nettoie les skipped keys expirées
  void _cleanupSkippedKeys() {
    final expired = <String>[];
    
    for (final entry in _skippedKeys.entries) {
      if (entry.value.isExpired) {
        expired.add(entry.key);
      }
    }
    
    for (final key in expired) {
      _skippedKeys.remove(key);
    }
  }

  /// Vide le cache (pour tests ou nettoyage)
  void clear() {
    _cache.clear();
    _skippedKeys.clear();
    debugPrint('🗑️ MessageKeyCache vidé');
  }

  /// Obtient les statistiques du cache
  Map<String, dynamic> getStats() {
    final activeKeys = _cache.values.where((k) => !k.isExpired).length;
    final skippedActive = _skippedKeys.values.where((k) => !k.isExpired).length;
    
    return {
      'total_cached': _cache.length,
      'active_keys': activeKeys,
      'skipped_keys': _skippedKeys.length,
      'skipped_active': skippedActive,
      'max_size': _maxCacheSize,
    };
  }
}

/// Entrée dans le cache de message keys
class _CachedMessageKey {
  final Uint8List key;
  final DateTime timestamp;
  final Duration ttl;

  _CachedMessageKey({
    required this.key,
    required this.timestamp,
    required this.ttl,
  });

  bool get isExpired => DateTime.now().difference(timestamp) > ttl;
}

