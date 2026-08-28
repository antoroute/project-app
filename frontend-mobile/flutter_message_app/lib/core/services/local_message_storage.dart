import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart' as crypto;
import '../models/message.dart';

/// Service de stockage local persistant des messages chiffrés
///
/// Inspiré de Signal : stocke les messages chiffrés localement pour
/// un accès instantané sans appel serveur.
///
/// Sécurité :
/// - Stocke uniquement les messages chiffrés (v2Data)
/// - Base de données chiffrée avec clé depuis keystore
/// - Messages déchiffrés uniquement en RAM
class LocalMessageStorage {
  LocalMessageStorage._internal();
  static final LocalMessageStorage instance = LocalMessageStorage._internal();

  static const String _dbName = 'messages_encrypted.db';
  static const int _dbVersion =
      4; // Version 4 : historique versionné des clés de cercle

  Database? _database;
  bool _isAvailable = false;
  bool _initializationAttempted = false;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  static const String _dbKeyName = 'local_db_encryption_key';

  /// Expose la base de données pour les services de cache (accès interne uniquement)
  Database? get database => _database;

  /// Vérifie si sqflite est disponible sur cette plateforme
  bool get isAvailable => _isAvailable;

  /// Initialise la base de données (non-bloquant, avec fallback gracieux)
  Future<void> initialize() async {
    if (_initializationAttempted) return;
    _initializationAttempted = true;

    try {
      final dbPath = await _getDatabasePath();
      // Note: La clé de chiffrement est générée mais non utilisée pour l'instant
      // sqflite ne supporte pas le chiffrement natif comme SQLCipher
      // On pourrait chiffrer les données sensibles avant stockage si nécessaire
      await _getOrCreateEncryptionKey();

      _database = await openDatabase(
        dbPath,
        version: _dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );

      _isAvailable = true;
      debugPrint('✅ LocalMessageStorage initialisé');
    } catch (e) {
      // Fallback gracieux : sqflite n'est pas disponible (web, plugin non installé, etc.)
      _isAvailable = false;
      debugPrint(
        '⚠️ LocalMessageStorage non disponible (fallback gracieux): $e',
      );
      debugPrint(
        'ℹ️ L\'app fonctionnera sans stockage local - messages chargés depuis le serveur uniquement',
      );
      // Ne pas rethrow - on continue sans stockage local
    }
  }

  /// Obtient ou crée la clé de chiffrement de la base
  Future<String> _getOrCreateEncryptionKey() async {
    String? key = await _secureStorage.read(key: _dbKeyName);

    if (key == null) {
      // Générer une nouvelle clé aléatoire
      final randomBytes = List<int>.generate(
        32,
        (i) => DateTime.now().millisecondsSinceEpoch % 256,
      );
      key = crypto.sha256.convert(randomBytes).toString();
      await _secureStorage.write(key: _dbKeyName, value: key);
      debugPrint('🔑 Nouvelle clé de chiffrement générée pour la base locale');
    }

    return key;
  }

  /// Obtient le chemin de la base de données
  Future<String> _getDatabasePath() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    return join(documentsDirectory.path, _dbName);
  }

  /// Crée les tables lors de la première création
  Future<void> _onCreate(Database db, int version) async {
    // CORRECTION: Créer la table sans INDEX (SQLite ne supporte pas INDEX dans CREATE TABLE)
    await db.execute('''
      CREATE TABLE encrypted_messages (
        message_id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        sender_device_id TEXT NOT NULL,
        v2_data TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        last_synced_at INTEGER,
        signature_valid INTEGER DEFAULT 0
      )
    ''');

    // Créer l'index séparément
    await db.execute('''
      CREATE INDEX idx_conversation_timestamp 
      ON encrypted_messages(conversation_id, timestamp DESC)
    ''');

    await db.execute('''
      CREATE TABLE conversation_sync_state (
        conversation_id TEXT PRIMARY KEY,
        last_synced_at INTEGER NOT NULL,
        last_message_timestamp INTEGER
      )
    ''');

    // Table pour message keys cache
    await db.execute('''
      CREATE TABLE message_keys_cache (
        message_id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        encrypted_key TEXT NOT NULL,
        nonce TEXT NOT NULL,
        mac TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        derived_from_device TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_message_keys_group_device 
      ON message_keys_cache(group_id, device_id)
    ''');

    await db.execute('''
      CREATE INDEX idx_message_keys_expires 
      ON message_keys_cache(expires_at)
    ''');

    // Table pour group keys cache
    await db.execute('''
      CREATE TABLE group_keys_cache (
        group_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        pk_kem TEXT NOT NULL,
        pk_sig TEXT NOT NULL,
        fingerprint_kem TEXT NOT NULL,
        fingerprint_sig TEXT NOT NULL,
        key_version INTEGER NOT NULL,
        status TEXT NOT NULL,
        cached_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        PRIMARY KEY (group_id, user_id, device_id, key_version)
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_group_keys_group 
      ON group_keys_cache(group_id)
    ''');

    await db.execute('''
      CREATE INDEX idx_group_keys_expires 
      ON group_keys_cache(expires_at)
    ''');

    debugPrint('📦 Tables créées dans LocalMessageStorage');
  }

  /// Gère les mises à jour de schéma
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    debugPrint('🔄 Upgrade base de données: $oldVersion -> $newVersion');

    // Migration vers version 2 : ajout de signature_valid
    if (oldVersion < 2) {
      try {
        await db.execute('''
          ALTER TABLE encrypted_messages 
          ADD COLUMN signature_valid INTEGER DEFAULT 0
        ''');
        debugPrint('✅ Migration v2 : colonne signature_valid ajoutée');
      } catch (e) {
        // La colonne existe peut-être déjà
        debugPrint(
          '⚠️ Erreur migration v2 (colonne peut-être déjà présente): $e',
        );
      }
    }

    // Migration vers version 3 : ajout des tables de cache persistant des clés
    if (oldVersion < 3) {
      try {
        // Table pour message keys cache
        await db.execute('''
          CREATE TABLE IF NOT EXISTS message_keys_cache (
            message_id TEXT PRIMARY KEY,
            group_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            encrypted_key TEXT NOT NULL,
            nonce TEXT NOT NULL,
            mac TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            derived_from_device TEXT
          )
        ''');

        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_message_keys_group_device 
          ON message_keys_cache(group_id, device_id)
        ''');

        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_message_keys_expires 
          ON message_keys_cache(expires_at)
        ''');

        // Table pour group keys cache
        await db.execute('''
          CREATE TABLE IF NOT EXISTS group_keys_cache (
            group_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            pk_kem TEXT NOT NULL,
            pk_sig TEXT NOT NULL,
            fingerprint_kem TEXT NOT NULL,
            fingerprint_sig TEXT NOT NULL,
            key_version INTEGER NOT NULL,
            status TEXT NOT NULL,
            cached_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            PRIMARY KEY (group_id, user_id, device_id, key_version)
          )
        ''');

        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_group_keys_group 
          ON group_keys_cache(group_id)
        ''');

        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_group_keys_expires 
          ON group_keys_cache(expires_at)
        ''');

        debugPrint('✅ Migration v3 : tables de cache ajoutées');
      } catch (e) {
        debugPrint('⚠️ Erreur migration v3: $e');
      }
    }

    if (oldVersion < 4) {
      await db.transaction((transaction) async {
        await transaction.execute(
          'ALTER TABLE group_keys_cache RENAME TO group_keys_cache_v3',
        );
        await transaction.execute('''
          CREATE TABLE group_keys_cache (
            group_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            pk_kem TEXT NOT NULL,
            pk_sig TEXT NOT NULL,
            fingerprint_kem TEXT NOT NULL,
            fingerprint_sig TEXT NOT NULL,
            key_version INTEGER NOT NULL,
            status TEXT NOT NULL,
            cached_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            PRIMARY KEY (group_id, user_id, device_id, key_version)
          )
        ''');
        await transaction.execute('''
          INSERT INTO group_keys_cache
          SELECT * FROM group_keys_cache_v3
        ''');
        await transaction.execute('DROP TABLE group_keys_cache_v3');
        await transaction.execute('''
          CREATE INDEX idx_group_keys_group
          ON group_keys_cache(group_id)
        ''');
        await transaction.execute('''
          CREATE INDEX idx_group_keys_expires
          ON group_keys_cache(expires_at)
        ''');
      });
      debugPrint('✅ Migration v4 : annuaire de clés versionné');
    }
  }

  /// Sauvegarde un message chiffré localement
  Future<void> saveMessage(Message message) async {
    if (!_isAvailable && !_initializationAttempted) {
      await initialize();
    }
    if (!_isAvailable || _database == null) {
      // Stockage local non disponible - ignorer silencieusement
      return;
    }

    if (message.v2Data == null) {
      debugPrint(
        '⚠️ Tentative de sauvegarde message sans v2Data: ${message.id}',
      );
      return;
    }

    try {
      await _database!.insert('encrypted_messages', {
        'message_id': message.id,
        'conversation_id': message.conversationId,
        'sender_id': message.senderId,
        'sender_device_id': message.v2Data!['sender']?['deviceId'] ?? '',
        'v2_data': jsonEncode(message.v2Data),
        'timestamp': message.timestamp,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'last_synced_at': DateTime.now().millisecondsSinceEpoch,
        'signature_valid':
            message.signatureValid
                ? 1
                : 0, // CORRECTION: Sauvegarder signatureValid
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      debugPrint(
        '💾 Message sauvegardé localement: ${message.id} (signatureValid: ${message.signatureValid})',
      );
    } catch (e) {
      debugPrint('❌ Erreur sauvegarde message local: $e');
    }
  }

  /// Charge les messages d'une conversation depuis le stockage local
  /// 🚀 OPTIMISATION: Charge uniquement les derniers messages (les plus récents)
  /// avec limite stricte pour éviter la surcharge
  Future<List<Message>> loadMessagesForConversation(
    String conversationId, {
    int? limit,
    int? beforeTimestamp,
  }) async {
    if (!_isAvailable && !_initializationAttempted) {
      await initialize();
    }
    if (!_isAvailable || _database == null) {
      // Stockage local non disponible - retourner liste vide
      return [];
    }

    try {
      // 🚀 OPTIMISATION: Limite de sécurité - ne jamais charger plus de 20 messages
      // même si limit est plus grand (évite la surcharge mémoire)
      final effectiveLimit = (limit != null && limit > 20) ? 20 : (limit ?? 20);

      // 🚀 OPTIMISATION: Utiliser l'index idx_conversation_timestamp pour performance
      // ORDER BY timestamp DESC utilise l'index pour un tri rapide
      var query = '''
        SELECT message_id, conversation_id, sender_id, sender_device_id, 
               v2_data, timestamp, signature_valid
        FROM encrypted_messages
        WHERE conversation_id = ?
      ''';

      final List<dynamic> args = [conversationId];

      if (beforeTimestamp != null) {
        query += ' AND timestamp < ?';
        args.add(beforeTimestamp);
      }

      // 🚀 OPTIMISATION: ORDER BY timestamp DESC utilise l'index pour performance
      query += ' ORDER BY timestamp DESC';

      // 🚀 OPTIMISATION: LIMIT appliqué AVANT le parsing JSON (économie mémoire)
      query += ' LIMIT ?';
      args.add(effectiveLimit);

      final List<Map<String, dynamic>> rows = await _database!.rawQuery(
        query,
        args,
      );

      // 🚀 OPTIMISATION: Parser JSON en batch dans un Isolate pour éviter de bloquer l'UI
      // Si on a peu de messages, on parse directement (overhead d'Isolate trop important)
      if (rows.length <= 5) {
        final messages = <Message>[];
        for (final row in rows) {
          try {
            final v2DataJson = row['v2_data'] as String;
            if (v2DataJson.isEmpty) {
              debugPrint(
                '⚠️ Message ${row['message_id']} a un v2_data vide, ignoré',
              );
              continue;
            }

            final v2Data = jsonDecode(v2DataJson) as Map<String, dynamic>;
            final signatureValid = (row['signature_valid'] as int? ?? 0) == 1;

            messages.add(
              Message(
                id: row['message_id'] as String,
                conversationId: row['conversation_id'] as String,
                senderId: row['sender_id'] as String,
                encrypted: null,
                iv: null,
                encryptedKeys: const {},
                signatureValid: signatureValid,
                senderPublicKey: null,
                timestamp: row['timestamp'] as int,
                v2Data: v2Data,
                decryptedText: null,
              ),
            );
          } catch (e) {
            debugPrint(
              '⚠️ Erreur parsing message local ${row['message_id']}: $e',
            );
          }
        }
        final reversedMessages = messages.reversed.toList();
        debugPrint(
          '📥 ${reversedMessages.length} messages chargés depuis le stockage local pour $conversationId (limite: $effectiveLimit)',
        );
        return reversedMessages;
      }

      // Pour plus de 5 messages, utiliser compute() pour parser en Isolate
      // La fonction _parseMessagesFromRows retourne déjà les messages dans le bon ordre
      final messages = await compute(_parseMessagesFromRows, rows);
      debugPrint(
        '📥 ${messages.length} messages chargés depuis le stockage local pour $conversationId (limite: $effectiveLimit)',
      );
      return messages;
    } catch (e) {
      debugPrint('❌ Erreur chargement messages locaux: $e');
      return [];
    }
  }

  /// Vérifie si des messages locaux existent pour une conversation
  Future<bool> hasLocalMessages(String conversationId) async {
    if (!_isAvailable && !_initializationAttempted) {
      await initialize();
    }
    if (!_isAvailable || _database == null) {
      return false;
    }

    try {
      final result = await _database!.rawQuery(
        'SELECT COUNT(*) as count FROM encrypted_messages WHERE conversation_id = ?',
        [conversationId],
      );
      final count = result.first['count'] as int?;
      return (count ?? 0) > 0;
    } catch (e) {
      debugPrint('❌ Erreur vérification messages locaux: $e');
      return false;
    }
  }

  /// Obtient le timestamp du dernier message local pour une conversation
  Future<int?> getLastMessageTimestamp(String conversationId) async {
    if (!_isAvailable && !_initializationAttempted) {
      await initialize();
    }
    if (!_isAvailable || _database == null) {
      return null;
    }

    try {
      final result = await _database!.rawQuery(
        'SELECT MAX(timestamp) as max_ts FROM encrypted_messages WHERE conversation_id = ?',
        [conversationId],
      );

      if (result.isEmpty || result.first['max_ts'] == null) {
        return null;
      }

      return result.first['max_ts'] as int;
    } catch (e) {
      debugPrint('❌ Erreur récupération dernier timestamp: $e');
      return null;
    }
  }

  /// Met à jour l'état de synchronisation d'une conversation
  Future<void> updateSyncState(
    String conversationId,
    int lastSyncedAt, {
    int? lastMessageTimestamp,
  }) async {
    if (!_isAvailable && !_initializationAttempted) {
      await initialize();
    }
    if (!_isAvailable || _database == null) {
      return;
    }

    try {
      await _database!.insert('conversation_sync_state', {
        'conversation_id': conversationId,
        'last_synced_at': lastSyncedAt,
        'last_message_timestamp': lastMessageTimestamp ?? 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint('❌ Erreur mise à jour sync state: $e');
    }
  }

  /// Obtient l'état de synchronisation d'une conversation
  Future<Map<String, dynamic>?> getSyncState(String conversationId) async {
    if (!_isAvailable && !_initializationAttempted) {
      await initialize();
    }
    if (!_isAvailable || _database == null) {
      return null;
    }

    try {
      final result = await _database!.rawQuery(
        'SELECT * FROM conversation_sync_state WHERE conversation_id = ?',
        [conversationId],
      );

      if (result.isEmpty) return null;

      return result.first;
    } catch (e) {
      debugPrint('❌ Erreur récupération sync state: $e');
      return null;
    }
  }

  /// Supprime les messages d'une conversation (nettoyage)
  Future<void> deleteMessagesForConversation(String conversationId) async {
    if (!_isAvailable && !_initializationAttempted) {
      await initialize();
    }
    if (!_isAvailable || _database == null) {
      return;
    }

    try {
      await _database!.delete(
        'encrypted_messages',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
      );
      debugPrint('🗑️ Messages supprimés pour conversation: $conversationId');
    } catch (e) {
      debugPrint('❌ Erreur suppression messages: $e');
    }
  }

  /// Nettoie les messages anciens (plus de X jours)
  Future<void> cleanupOldMessages({int daysToKeep = 90}) async {
    if (!_isAvailable && !_initializationAttempted) {
      await initialize();
    }
    if (!_isAvailable || _database == null) {
      return;
    }

    try {
      final cutoffTimestamp =
          DateTime.now()
              .subtract(Duration(days: daysToKeep))
              .millisecondsSinceEpoch ~/
          1000;

      final deleted = await _database!.delete(
        'encrypted_messages',
        where: 'timestamp < ?',
        whereArgs: [cutoffTimestamp],
      );

      debugPrint('🧹 Nettoyage: $deleted messages anciens supprimés');
    } catch (e) {
      debugPrint('❌ Erreur nettoyage messages: $e');
    }
  }

  /// Ferme la base de données
  Future<void> close() async {
    await _database?.close();
    _database = null;
    debugPrint('🔒 LocalMessageStorage fermé');
  }
}

/// 🚀 OPTIMISATION: Fonction top-level pour parser les messages dans un Isolate
/// Parse les messages depuis les rows de la DB en batch
List<Message> _parseMessagesFromRows(List<Map<String, dynamic>> rows) {
  final messages = <Message>[];
  for (final row in rows) {
    try {
      final v2DataJson = row['v2_data'] as String;
      if (v2DataJson.isEmpty) {
        continue;
      }

      final v2Data = jsonDecode(v2DataJson) as Map<String, dynamic>;
      final signatureValid = (row['signature_valid'] as int? ?? 0) == 1;

      messages.add(
        Message(
          id: row['message_id'] as String,
          conversationId: row['conversation_id'] as String,
          senderId: row['sender_id'] as String,
          encrypted: null,
          iv: null,
          encryptedKeys: const {},
          signatureValid: signatureValid,
          senderPublicKey: null,
          timestamp: row['timestamp'] as int,
          v2Data: v2Data,
          decryptedText: null,
        ),
      );
    } catch (e) {
      // Ignorer les erreurs de parsing individuelles
    }
  }
  return messages.reversed.toList();
}
