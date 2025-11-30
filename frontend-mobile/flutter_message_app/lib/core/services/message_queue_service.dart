import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

/// Service pour gérer une queue de messages en attente quand le WebSocket est déconnecté
class MessageQueueService {
  static final MessageQueueService _instance = MessageQueueService._internal();
  factory MessageQueueService() => _instance;
  MessageQueueService._internal();

  Database? _database;
  static const String _tableName = 'message_queue';
  static const int _dbVersion = 1;

  /// Initialise la base de données pour la queue
  Future<void> initialize() async {
    if (_database != null) return;

    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, 'message_queue.db');

    _database = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT NOT NULL,
            message_data TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            retry_count INTEGER DEFAULT 0
          )
        ''');
        debugPrint('📦 [MessageQueue] Table créée');
      },
    );
    debugPrint('📦 [MessageQueue] Base de données initialisée');
  }

  /// Ajoute un message à la queue
  Future<void> enqueueMessage({
    required String conversationId,
    required Map<String, dynamic> messageData,
  }) async {
    if (_database == null) {
      await initialize();
    }

    try {
      await _database!.insert(
        _tableName,
        {
          'conversation_id': conversationId,
          'message_data': messageData.toString(), // TODO: Sérialiser en JSON
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'retry_count': 0,
        },
      );
      debugPrint('📦 [MessageQueue] Message ajouté à la queue pour conversation $conversationId');
    } catch (e) {
      debugPrint('❌ [MessageQueue] Erreur ajout message: $e');
    }
  }

  /// Récupère tous les messages en attente
  Future<List<Map<String, dynamic>>> getPendingMessages() async {
    if (_database == null) {
      await initialize();
    }

    try {
      final results = await _database!.query(
        _tableName,
        orderBy: 'created_at ASC',
      );
      debugPrint('📦 [MessageQueue] ${results.length} messages en attente');
      return results;
    } catch (e) {
      debugPrint('❌ [MessageQueue] Erreur récupération messages: $e');
      return [];
    }
  }

  /// Supprime un message de la queue après envoi réussi
  Future<void> removeMessage(int messageId) async {
    if (_database == null) return;

    try {
      await _database!.delete(
        _tableName,
        where: 'id = ?',
        whereArgs: [messageId],
      );
      debugPrint('📦 [MessageQueue] Message $messageId supprimé de la queue');
    } catch (e) {
      debugPrint('❌ [MessageQueue] Erreur suppression message: $e');
    }
  }

  /// Incrémente le compteur de tentatives pour un message
  Future<void> incrementRetryCount(int messageId) async {
    if (_database == null) return;

    try {
      await _database!.update(
        _tableName,
        {'retry_count': Sqflite.firstIntValue(
          await _database!.rawQuery(
            'SELECT retry_count FROM $_tableName WHERE id = ?',
            [messageId],
          ),
        )! + 1},
        where: 'id = ?',
        whereArgs: [messageId],
      );
    } catch (e) {
      debugPrint('❌ [MessageQueue] Erreur incrément retry: $e');
    }
  }

  /// Vide la queue (utile pour nettoyer les anciens messages)
  Future<void> clearQueue() async {
    if (_database == null) return;

    try {
      await _database!.delete(_tableName);
      debugPrint('📦 [MessageQueue] Queue vidée');
    } catch (e) {
      debugPrint('❌ [MessageQueue] Erreur vidage queue: $e');
    }
  }

  /// Nettoie les messages trop anciens (plus de 24h)
  Future<void> cleanupOldMessages() async {
    if (_database == null) return;

    try {
      final cutoffTime = DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch;
      await _database!.delete(
        _tableName,
        where: 'created_at < ?',
        whereArgs: [cutoffTime],
      );
      debugPrint('📦 [MessageQueue] Messages anciens nettoyés');
    } catch (e) {
      debugPrint('❌ [MessageQueue] Erreur nettoyage: $e');
    }
  }

  /// Dispose le service
  Future<void> dispose() async {
    await _database?.close();
    _database = null;
    debugPrint('📦 [MessageQueue] Service disposé');
  }
}

