import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import '../crypto/key_manager_final.dart';
import '../services/key_directory_service.dart';
import '../crypto/crypto_isolate_service.dart';
import '../crypto/crypto_isolate_data.dart';
import 'persistent_message_key_cache.dart';

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
      // 1. Vérifier cache mémoire d'abord
      final cached = _cache[messageId];
      if (cached != null && !cached.isExpired) {
        return cached.key;
      }
      
      // 2. Vérifier cache persistant
      final persistentKey = await PersistentMessageKeyCache.instance.getMessageKey(messageId);
      if (persistentKey != null) {
        // Mettre en cache mémoire aussi
        _cache[messageId] = _CachedMessageKey(
          key: persistentKey,
          timestamp: DateTime.now(),
          ttl: _defaultTtl,
        );
        return persistentKey;
      }
      
      // 3. Dériver la message key (code existant)
      final messageKey = await _deriveMessageKey(
        groupId: groupId,
        myUserId: myUserId,
        myDeviceId: myDeviceId,
        messageV2: messageV2,
      );

      if (messageKey != null) {
        // 4. Mettre en cache mémoire
        _cache[messageId] = _CachedMessageKey(
          key: messageKey,
          timestamp: DateTime.now(),
          ttl: _defaultTtl,
        );
        
        // 5. Sauvegarder dans cache persistant (non-bloquant)
        final sender = messageV2['sender'] as Map<String, dynamic>?;
        final derivedFromDevice = sender?['deviceId'] as String?;
        
        PersistentMessageKeyCache.instance.saveMessageKey(
          messageId: messageId,
          groupId: groupId,
          userId: myUserId,
          deviceId: myDeviceId,
          messageKey: messageKey,
          derivedFromDevice: derivedFromDevice,
        ).catchError((e) {
          debugPrint('⚠️ Erreur sauvegarde cache persistant: $e');
        });
        
        // Nettoyer si nécessaire
        _cleanupIfNeeded();
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

      // 🚀 OPTIMISATION: X25519 ECDH dans un Isolate (goulot d'étranglement principal)
      // Extraire les bytes des clés (thread principal)
      final myPrivateKeyBytes = await KeyManagerFinal.instance.getX25519PrivateKeyBytes(groupId, myDeviceId);
      final remotePublicKeyBytes = base64.decode(ephPubB64.replaceAll(RegExp(r'[\s\n\r]'), ''));
      
      // Créer la tâche pour l'Isolate
      final task = X25519EcdhTask(
        taskId: '${groupId}_${myDeviceId}_${DateTime.now().millisecondsSinceEpoch}',
        myPrivateKeyBytes: myPrivateKeyBytes,
        remotePublicKeyBytes: remotePublicKeyBytes,
      );
      
      // Exécuter X25519 ECDH dans l'Isolate
      final ecdhResult = await CryptoIsolateService.instance.executeX25519Ecdh(task);
      
      if (ecdhResult.error != null) {
        debugPrint('❌ Erreur X25519 ECDH dans MessageKeyCache: ${ecdhResult.error}');
        return null;
      }
      
      if (ecdhResult.sharedSecretBytes == null) {
        debugPrint('❌ X25519 ECDH returned null shared secret');
        return null;
      }
      
      // Créer un SecretKey depuis les bytes pour HKDF
      final shared = SecretKey(ecdhResult.sharedSecretBytes!);

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
        return null;
      }

      // Unwrap la message key
      final aead = AesGcm.with256bits();
      final wrapBytes = base64.decode(mine['wrap'] as String);
      final wrapNonce = base64.decode(mine['nonce'] as String);
      final macLen = 16;
      
      // CORRECTION: Validation pour éviter RangeError
      if (wrapBytes.length < macLen) {
        return null;
      }
      
      final cipherLen = wrapBytes.length - macLen;
      if (cipherLen < 0) {
        return null;
      }
      
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

