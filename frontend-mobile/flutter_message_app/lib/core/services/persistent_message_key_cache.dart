import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'local_message_storage.dart';

/// Cache persistant des message keys avec chiffrement AES-256-GCM
///
/// Sécurité :
/// - Chiffrement AES-256-GCM avec clé maître depuis Keychain
/// - TTL de 7 jours avec nettoyage automatique
/// - Invalidation lors de révocation device
class PersistentMessageKeyCache {
  PersistentMessageKeyCache._internal();

  static final PersistentMessageKeyCache instance =
      PersistentMessageKeyCache._internal();

  static const String _tableName = 'message_keys_cache';
  static const Duration _ttl = Duration(days: 7);
  static const String _masterKeyPrefix = 'message_key_master:v2:account:';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  Timer? _cleanupTimer;
  final Map<String, Future<SecretKey>> _pendingMasterKeys =
      <String, Future<SecretKey>>{};

  Database? get _database => LocalMessageStorage.instance.database;

  /// Obtient ou crée la clé maître depuis Keychain
  Future<SecretKey> _getMasterKey(String userId) async {
    final pending = _pendingMasterKeys[userId];
    if (pending != null) return pending;

    final resolution = _loadOrCreateMasterKey(userId);
    _pendingMasterKeys[userId] = resolution;
    try {
      return await resolution;
    } finally {
      if (identical(_pendingMasterKeys[userId], resolution)) {
        _pendingMasterKeys.remove(userId);
      }
    }
  }

  Future<SecretKey> _loadOrCreateMasterKey(String userId) async {
    final masterKeyName = '$_masterKeyPrefix$userId';
    // Récupérer depuis Keychain
    String? masterKeyB64 = await _secureStorage.read(key: masterKeyName);

    if (masterKeyB64 == null) {
      // Générer nouvelle clé maître (32 bytes)
      final random = Random.secure();
      final masterKeyBytes = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      final masterKey = SecretKey(masterKeyBytes);
      masterKeyB64 = base64Encode(masterKeyBytes);

      // Stocker dans Keychain
      await _secureStorage.write(key: masterKeyName, value: masterKeyB64);
      debugPrint('🔑 Clé maître générée pour message keys cache');

      return masterKey;
    }

    // Reconstruire depuis Keychain
    final masterKeyBytes = base64Decode(masterKeyB64);
    if (masterKeyBytes.length != 32) {
      throw const FormatException('invalid message key cache master key');
    }
    return SecretKey(masterKeyBytes);
  }

  /// Sauvegarde une message key chiffrée
  Future<void> saveMessageKey({
    required String messageId,
    required String groupId,
    required String userId,
    required String deviceId,
    required Uint8List messageKey,
    String? derivedFromDevice,
  }) async {
    if (_database == null) {
      debugPrint('⚠️ Database non disponible pour message keys cache');
      return;
    }

    try {
      // Obtenir clé maître
      final masterKey = await _getMasterKey(userId);

      // Chiffrer la message key avec AES-256-GCM
      final aead = AesGcm.with256bits();
      final nonce = aead.newNonce();

      final secretBox = await aead.encrypt(
        messageKey,
        secretKey: masterKey,
        nonce: nonce,
      );

      // Stocker dans SQLite
      final now = DateTime.now().millisecondsSinceEpoch;
      final expiresAt = now + _ttl.inMilliseconds;

      await _database!.insert(_tableName, {
        'message_id': messageId,
        'group_id': groupId,
        'user_id': userId,
        'device_id': deviceId,
        'encrypted_key': base64Encode(secretBox.cipherText),
        'nonce': base64Encode(secretBox.nonce),
        'mac': base64Encode(secretBox.mac.bytes),
        'created_at': now,
        'expires_at': expiresAt,
        'derived_from_device': derivedFromDevice,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      debugPrint('💾 Message key sauvegardée (chiffrée): $messageId');
    } catch (e) {
      debugPrint('❌ Erreur sauvegarde message key: $e');
      // Ne pas rethrow - cache persistant est optionnel
    }
  }

  /// Récupère une message key déchiffrée
  Future<Uint8List?> getMessageKey({
    required String messageId,
    required String userId,
    required String deviceId,
  }) async {
    if (_database == null) return null;

    try {
      // Récupérer depuis SQLite
      final rows = await _database!.query(
        _tableName,
        where:
            'message_id = ? AND user_id = ? AND device_id = ? AND expires_at > ?',
        whereArgs: [
          messageId,
          userId,
          deviceId,
          DateTime.now().millisecondsSinceEpoch,
        ],
        limit: 1,
      );

      if (rows.isEmpty) return null;

      final row = rows.first;

      // Déchiffrer avec clé maître
      final masterKey = await _getMasterKey(userId);
      final aead = AesGcm.with256bits();

      final secretBox = SecretBox(
        base64Decode(row['encrypted_key'] as String),
        nonce: base64Decode(row['nonce'] as String),
        mac: Mac(base64Decode(row['mac'] as String)),
      );

      final decrypted = await aead.decrypt(secretBox, secretKey: masterKey);

      debugPrint(
        '📥 Message key récupérée depuis cache persistant: $messageId',
      );
      return Uint8List.fromList(decrypted);
    } catch (e) {
      debugPrint('❌ Erreur récupération message key: $e');
      return null;
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
        debugPrint(
          '🧹 Nettoyage message keys: $deleted clés expirées supprimées',
        );
      }
    } catch (e) {
      debugPrint('❌ Erreur nettoyage message keys: $e');
    }
  }

  /// Invalide les clés pour un device révoqué
  Future<void> invalidateKeysForDevice(String groupId, String deviceId) async {
    if (_database == null) return;

    try {
      final deleted = await _database!.delete(
        _tableName,
        where: 'group_id = ? AND (device_id = ? OR derived_from_device = ?)',
        whereArgs: [groupId, deviceId, deviceId],
      );

      if (deleted > 0) {
        debugPrint(
          '🗑️ Invalidation message keys pour device $deviceId: $deleted clés supprimées',
        );
      }
    } catch (e) {
      debugPrint('❌ Erreur invalidation message keys: $e');
    }
  }

  /// Vide le cache (pour tests ou nettoyage)
  Future<void> clear() async {
    if (_database == null) return;

    try {
      await _database!.delete(_tableName);
      debugPrint('🗑️ Cache message keys vidé');
    } catch (e) {
      debugPrint('❌ Erreur vidage cache message keys: $e');
    }
  }

  /// Démarre le nettoyage périodique (toutes les 6 heures)
  void startPeriodicCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(hours: 6), (_) {
      cleanupExpiredKeys();
    });
    debugPrint(
      '🔄 Nettoyage périodique message keys démarré (toutes les 6 heures)',
    );
  }

  /// Arrête le nettoyage périodique
  void stopPeriodicCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    debugPrint('⏹️ Nettoyage périodique message keys arrêté');
  }
}
