import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_message_app/core/services/api_service.dart';
import 'local_message_storage.dart';

/// Structure d'une entrée (user, device) et clés publiques + empreintes
class GroupDeviceKeyEntry {
  final String userId;
  final String deviceId;
  final String pkSigB64; // Ed25519 public key (32B) base64
  final String pkKemB64; // X25519 public key (32B) base64
  final int keyVersion;
  final String status;

  // Pinning (empreintes SHA-256 sur les pubs)
  final String fingerprintSig; // hex
  final String fingerprintKem; // hex

  GroupDeviceKeyEntry({
    required this.userId,
    required this.deviceId,
    required this.pkSigB64,
    required this.pkKemB64,
    required this.keyVersion,
    required this.status,
    required this.fingerprintSig,
    required this.fingerprintKem,
  });

  static String _sha256HexFromBase64(String b64) {
    final bytes = base64.decode(b64);
    final digest = sha256.convert(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  factory GroupDeviceKeyEntry.fromJson(Map<String, dynamic> json) {
    final pkSig = json['pk_sig'] as String;
    final pkKem = json['pk_kem'] as String;
    return GroupDeviceKeyEntry(
      userId: json['userId'] as String,
      deviceId: json['deviceId'] as String,
      pkSigB64: pkSig,
      pkKemB64: pkKem,
      keyVersion: (json['key_version'] as num).toInt(),
      status: json['status'] as String? ?? 'active',
      fingerprintSig: _sha256HexFromBase64(pkSig),
      fingerprintKem: _sha256HexFromBase64(pkKem),
    );
  }
}

/// Service d'annuaire des clés par groupe avec cache + pinning
class KeyDirectoryService {
  KeyDirectoryService(this._api);

  final ApiService _api;

  // Cache en mémoire: groupId -> entries
  final Map<String, List<GroupDeviceKeyEntry>> _cache = <String, List<GroupDeviceKeyEntry>>{};
  
  // CORRECTION: Protection contre les appels simultanés
  final Map<String, Future<List<GroupDeviceKeyEntry>>> _pendingRequests = <String, Future<List<GroupDeviceKeyEntry>>>{};
  
  static const String _tableName = 'group_keys_cache';
  static const Duration _ttl = Duration(days: 30);
  
  Database? get _database => LocalMessageStorage.instance.database;

  /// Récupère et met en cache la liste (user,device,keys) d'un groupe
  Future<List<GroupDeviceKeyEntry>> fetchGroupDevices(String groupId) async {
    final raw = await _api.fetchGroupDeviceKeys(groupId);
    final entries = raw.map((e) => GroupDeviceKeyEntry.fromJson(e)).toList();
    
    // Mettre en cache mémoire
    _cache[groupId] = entries;
    
    // Sauvegarder dans cache persistant (non-bloquant)
    _saveGroupKeysToPersistentCache(groupId, entries).catchError((e) {
      debugPrint('⚠️ Erreur sauvegarde cache persistant group keys: $e');
    });
    
    return entries;
  }

  /// Retourne les entrées en cache si dispo, sinon fetch
  Future<List<GroupDeviceKeyEntry>> getGroupDevices(String groupId) async {
    // 1. Vérifier cache mémoire d'abord
    final cached = _cache[groupId];
    if (cached != null) {
      // Vérifier si proche expiration et refresh en arrière-plan
      _checkAndRefreshIfNeeded(groupId);
      return cached;
    }
    
    // 2. Vérifier cache persistant
    final persistentEntries = await _getGroupKeysFromPersistentCache(groupId);
    if (persistentEntries != null && persistentEntries.isNotEmpty) {
      // Mettre en cache mémoire aussi
      _cache[groupId] = persistentEntries;
      
      // Refresh en arrière-plan si proche expiration
      _checkAndRefreshIfNeeded(groupId);
      
      return persistentEntries;
    }
    
    // 3. CORRECTION: Éviter les appels simultanés pour le même groupe
    final pending = _pendingRequests[groupId];
    if (pending != null) {
      return pending;
    }
    
    // Créer une nouvelle requête et la mettre en cache
    final future = fetchGroupDevices(groupId);
    _pendingRequests[groupId] = future;
    
    try {
      final result = await future;
      return result;
    } finally {
      // Nettoyer la requête en cours
      _pendingRequests.remove(groupId);
    }
  }

  /// Helper: filtre par liste d'utilisateurs; retourne toutes leurs devices actives
  Future<List<GroupDeviceKeyEntry>> devicesForUsers(String groupId, List<String> userIds) async {
    final all = await getGroupDevices(groupId);
    final set = userIds.toSet();
    return all.where((e) => set.contains(e.userId) && e.status == 'active').toList();
  }

  /// Sauvegarde les clés de groupe dans le cache persistant
  Future<void> _saveGroupKeysToPersistentCache(
    String groupId,
    List<GroupDeviceKeyEntry> entries,
  ) async {
    if (_database == null) return;
    
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final expiresAt = now + _ttl.inMilliseconds;
      
      // Supprimer anciennes entrées pour ce groupe
      await _database!.delete(
        _tableName,
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
      
      // Insérer nouvelles entrées
      final batch = _database!.batch();
      for (final entry in entries) {
        batch.insert(
          _tableName,
          {
            'group_id': groupId,
            'user_id': entry.userId,
            'device_id': entry.deviceId,
            'pk_kem': entry.pkKemB64,
            'pk_sig': entry.pkSigB64,
            'fingerprint_kem': entry.fingerprintKem,
            'fingerprint_sig': entry.fingerprintSig,
            'key_version': entry.keyVersion,
            'status': entry.status,
            'cached_at': now,
            'expires_at': expiresAt,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      
      debugPrint('💾 Group keys sauvegardées dans cache persistant: $groupId (${entries.length} devices)');
    } catch (e) {
      debugPrint('❌ Erreur sauvegarde group keys cache: $e');
    }
  }
  
  /// Récupère les clés de groupe depuis le cache persistant
  Future<List<GroupDeviceKeyEntry>?> _getGroupKeysFromPersistentCache(String groupId) async {
    if (_database == null) return null;
    
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await _database!.query(
        _tableName,
        where: 'group_id = ? AND expires_at > ?',
        whereArgs: [groupId, now],
      );
      
      if (rows.isEmpty) return null;
      
      final entries = <GroupDeviceKeyEntry>[];
      for (final row in rows) {
        // Valider fingerprint avant utilisation
        final pkKem = row['pk_kem'] as String;
        final storedFingerprint = row['fingerprint_kem'] as String;
        final computedFingerprint = sha256
            .convert(base64Decode(pkKem))
            .bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        
        if (storedFingerprint != computedFingerprint) {
          debugPrint('⚠️ Fingerprint invalide pour device ${row['device_id']}, invalidation cache');
          invalidateCache(groupId);
          return null;
        }
        
        entries.add(GroupDeviceKeyEntry(
          userId: row['user_id'] as String,
          deviceId: row['device_id'] as String,
          pkSigB64: row['pk_sig'] as String,
          pkKemB64: pkKem,
          keyVersion: row['key_version'] as int,
          status: row['status'] as String,
          fingerprintSig: row['fingerprint_sig'] as String,
          fingerprintKem: storedFingerprint,
        ));
      }
      
      debugPrint('📥 Group keys récupérées depuis cache persistant: $groupId (${entries.length} devices)');
      return entries;
    } catch (e) {
      debugPrint('❌ Erreur récupération group keys cache: $e');
      return null;
    }
  }
  
  /// Vérifie si le cache est proche expiration et refresh si nécessaire
  void _checkAndRefreshIfNeeded(String groupId) {
    if (_database == null) return;
    
    // Vérifier en arrière-plan (non-bloquant)
    _database!.query(
      _tableName,
      columns: ['expires_at'],
      where: 'group_id = ?',
      whereArgs: [groupId],
      limit: 1,
    ).then((rows) {
      if (rows.isEmpty) return;
      
      final expiresAt = rows.first['expires_at'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      final timeUntilExpiry = expiresAt - now;
      final sevenDays = Duration(days: 7).inMilliseconds;
      
      // Si expire dans moins de 7 jours, refresh en arrière-plan
      if (timeUntilExpiry < sevenDays) {
        debugPrint('🔄 Refresh group keys en arrière-plan: $groupId');
        fetchGroupDevices(groupId).catchError((e) {
          debugPrint('⚠️ Erreur refresh group keys: $e');
          return <GroupDeviceKeyEntry>[];
        });
      }
    }).catchError((e) {
      debugPrint('⚠️ Erreur vérification expiration group keys: $e');
    });
  }
  
  /// Invalide le cache pour un groupe (utile après révocation d'un device)
  void invalidateCache(String groupId) {
    _cache.remove(groupId);
    _pendingRequests.remove(groupId);
    
    // Invalider aussi le cache persistant
    if (_database != null) {
      _database!.delete(
        _tableName,
        where: 'group_id = ?',
        whereArgs: [groupId],
      ).then((deleted) {
        if (deleted > 0) {
          debugPrint('🗑️ Cache persistant invalidé pour groupe $groupId: $deleted entrées supprimées');
        }
      }).catchError((e) {
        debugPrint('⚠️ Erreur invalidation cache persistant: $e');
      });
    }
  }
  
  /// Invalide les clés pour un device spécifique
  Future<void> invalidateDeviceKeys(String groupId, String deviceId) async {
    if (_database == null) return;
    
    try {
      await _database!.delete(
        _tableName,
        where: 'group_id = ? AND device_id = ?',
        whereArgs: [groupId, deviceId],
      );
      
      // Invalider aussi le cache mémoire
      final cached = _cache[groupId];
      if (cached != null) {
        _cache[groupId] = cached.where((e) => e.deviceId != deviceId).toList();
      }
      
      debugPrint('🗑️ Clés invalidées pour device $deviceId dans groupe $groupId');
    } catch (e) {
      debugPrint('❌ Erreur invalidation device keys: $e');
    }
  }
  
  /// Nettoie les clés expirées
  Future<void> cleanupExpiredKeys() async {
    if (_database == null) return;
    
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final deleted = await _database!.delete(
        _tableName,
        where: 'expires_at < ?',
        whereArgs: [now],
      );
      
      if (deleted > 0) {
        debugPrint('🧹 Nettoyage group keys: $deleted entrées expirées supprimées');
      }
    } catch (e) {
      debugPrint('❌ Erreur nettoyage group keys: $e');
    }
  }
}


