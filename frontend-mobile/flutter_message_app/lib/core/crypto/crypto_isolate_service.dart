import 'dart:isolate';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'crypto_isolate_data.dart';
import 'crypto_isolate_worker.dart';

/// Service pour gérer l'Isolate de déchiffrement crypto
/// Focus sur X25519 ECDH (goulot d'étranglement principal)
class CryptoIsolateService {
  static final CryptoIsolateService instance = CryptoIsolateService._internal();
  CryptoIsolateService._internal();
  
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _resultPort;
  // Map pour stocker les completers de tous les types de tâches
  final Map<String, Completer<dynamic>> _pendingTasks = {};
  // Map pour stocker le type de chaque tâche (pour désérialiser correctement)
  final Map<String, String> _taskTypes = {};
  bool _isDisposed = false;
  
  StreamSubscription<dynamic>? _resultSubscription;
  Completer<void>? _startupCompleter;
  
  /// Démarre l'Isolate si nécessaire
  Future<void> _ensureStarted() async {
    if (_isolate != null && _sendPort != null && _resultPort != null) return;
    if (_isDisposed) throw Exception('Service disposed');
    
    debugPrint('🚀 [CryptoIsolate] Démarrage de l\'Isolate...');
    
    _startupCompleter = Completer<void>();
    
    // Port pour recevoir les résultats du worker
    _resultPort = ReceivePort();
    
    // Spawn l'Isolate en lui passant le SendPort du port de résultats
    _isolate = await Isolate.spawn(
      cryptoWorker,
      _resultPort!.sendPort,
      debugName: 'CryptoWorker',
    );
    
    // Écouter TOUS les messages (y compris le premier qui est le SendPort)
    _resultSubscription = _resultPort!.listen((message) {
      // Premier message = SendPort du port de commande du worker
      if (message is SendPort && _sendPort == null) {
        _sendPort = message;
        debugPrint('✅ [CryptoIsolate] Isolate démarré, SendPort reçu');
        if (!_startupCompleter!.isCompleted) {
          _startupCompleter!.complete();
        }
        return;
      }
      
      // Messages suivants = Résultats des tâches
      if (message is Map<String, dynamic>) {
        final taskId = message['taskId'] as String?;
        if (taskId != null) {
          debugPrint('📥 [CryptoIsolate] Réception résultat pour tâche: $taskId');
          final completer = _pendingTasks[taskId];
          
          // Si le completer n'existe pas encore, c'est une race condition
          // On va le traiter de manière asynchrone après un court délai
          if (completer == null) {
            debugPrint('⚠️ [CryptoIsolate] Completer pas encore enregistré pour $taskId, traitement différé...');
            // Traiter de manière asynchrone après un court délai
            Future.delayed(const Duration(milliseconds: 50), () {
              final retryCompleter = _pendingTasks[taskId];
              final retryTaskType = _taskTypes[taskId];
              if (retryCompleter != null && !retryCompleter.isCompleted) {
                debugPrint('✅ [CryptoIsolate] Completer trouvé après délai pour $taskId');
                _pendingTasks.remove(taskId);
                _taskTypes.remove(taskId);
                _processResult(message, taskId, retryCompleter, retryTaskType);
              } else {
                debugPrint('❌ [CryptoIsolate] Completer toujours introuvable après délai pour $taskId');
              }
            });
            return;
          }
          
          // Retirer de la map seulement après avoir trouvé le completer
          _pendingTasks.remove(taskId);
          final actualTaskType = _taskTypes.remove(taskId);
          
          _processResult(message, taskId, completer, actualTaskType);
        }
      }
    });
    
    // Attendre que le SendPort soit reçu (avec timeout)
    try {
      await _startupCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('Isolate startup timeout - SendPort not received');
        },
      );
    } finally {
      _startupCompleter = null;
    }
    
    // Gérer la mort de l'Isolate
    _isolate!.addOnExitListener(_resultPort!.sendPort);
  }
  
  /// Traite un résultat reçu de l'Isolate
  void _processResult(Map<String, dynamic> message, String taskId, Completer completer, String? taskType) {
    if (completer.isCompleted) {
      debugPrint('⚠️ [CryptoIsolate] Completer déjà complété pour $taskId');
      return;
    }
    
    if (message['error'] != null) {
      debugPrint('❌ [CryptoIsolate] Erreur pour tâche $taskId: ${message['error']}');
      completer.completeError(Exception(message['error']));
      return;
    }
    
    try {
      // Désérialiser selon le type de tâche
      dynamic result;
      if (taskType == 'x25519_ecdh') {
        result = X25519EcdhResult.fromJson(message);
        // Validation : si sharedSecretBytes est null, c'est une erreur
        if (result is X25519EcdhResult && result.sharedSecretBytes == null) {
          throw Exception('X25519 ECDH returned null shared secret (no error field)');
        }
      } else if (taskType == 'content_decrypt') {
        result = ContentDecryptResult.fromJson(message);
        // Validation : si decryptedTextBytesB64 est null, c'est une erreur
        if (result is ContentDecryptResult && result.decryptedTextBytesB64 == null) {
          throw Exception('ContentDecrypt returned null decrypted text (no error field)');
        }
      } else if (taskType == 'full_decrypt') {
        result = FullDecryptResult.fromJson(message);
        // Validation : si decryptedTextBytesB64 est null, c'est une erreur
        if (result is FullDecryptResult && result.decryptedTextBytesB64 == null) {
          throw Exception('FullDecrypt returned null decrypted text (no error field)');
        }
      } else {
        throw Exception('Type de tâche inconnu ou null: $taskType');
      }
      
      completer.complete(result);
      debugPrint('✅ [CryptoIsolate] Tâche $taskId complétée avec succès');
    } catch (e) {
      debugPrint('❌ [CryptoIsolate] Erreur parsing résultat pour $taskId: $e');
      completer.completeError(e);
    }
  }
  
  /// Exécute une tâche X25519 ECDH dans l'Isolate
  Future<X25519EcdhResult> executeX25519Ecdh(X25519EcdhTask task) async {
    await _ensureStarted();
    
    if (_isDisposed) {
      throw Exception('Service disposed');
    }
    
    final completer = Completer<X25519EcdhResult>();
    _pendingTasks[task.taskId] = completer;
    _taskTypes[task.taskId] = 'x25519_ecdh';
    
    // Timeout de sécurité (60 secondes - X25519 peut être lent sur mobile)
    Timer(const Duration(seconds: 60), () {
      if (_pendingTasks.containsKey(task.taskId)) {
        _pendingTasks.remove(task.taskId);
        _taskTypes.remove(task.taskId);
        if (!completer.isCompleted) {
          completer.completeError(TimeoutException('X25519 ECDH task timeout after 60s'));
        }
      }
    });
    
    debugPrint('📤 [CryptoIsolate] Envoi tâche X25519 ECDH: ${task.taskId}');
    
    _sendPort!.send({
      'type': 'x25519_ecdh',
      'data': task.toJson(),
    });
    
    return completer.future;
  }
  
  /// Exécute un déchiffrement de contenu uniquement (avec cache) dans l'Isolate
  Future<ContentDecryptResult> executeContentDecrypt(ContentDecryptTask task) async {
    await _ensureStarted();
    
    if (_isDisposed) {
      throw Exception('Service disposed');
    }
    
    final completer = Completer<ContentDecryptResult>();
    _pendingTasks[task.taskId] = completer;
    _taskTypes[task.taskId] = 'content_decrypt';
    
    // Timeout de sécurité (30 secondes - plus rapide, seulement AES)
    Timer(const Duration(seconds: 30), () {
      if (_pendingTasks.containsKey(task.taskId)) {
        _pendingTasks.remove(task.taskId);
        _taskTypes.remove(task.taskId);
        if (!completer.isCompleted) {
          completer.completeError(TimeoutException('Content decrypt task timeout after 30s'));
        }
      }
    });
    
    debugPrint('📤 [CryptoIsolate] Envoi tâche ContentDecrypt: ${task.taskId}');
    
    _sendPort!.send({
      'type': 'content_decrypt',
      'data': task.toJson(),
    });
    
    return completer.future;
  }
  
  /// Exécute un déchiffrement complet (sans cache) dans l'Isolate
  Future<FullDecryptResult> executeFullDecrypt(FullDecryptTask task) async {
    await _ensureStarted();
    
    if (_isDisposed) {
      throw Exception('Service disposed');
    }
    
    final completer = Completer<FullDecryptResult>();
    _pendingTasks[task.taskId] = completer;
    _taskTypes[task.taskId] = 'full_decrypt';
    
    // Timeout de sécurité (60 secondes - opération complète)
    Timer(const Duration(seconds: 60), () {
      if (_pendingTasks.containsKey(task.taskId)) {
        _pendingTasks.remove(task.taskId);
        _taskTypes.remove(task.taskId);
        if (!completer.isCompleted) {
          completer.completeError(TimeoutException('Full decrypt task timeout after 60s'));
        }
      }
    });
    
    debugPrint('📤 [CryptoIsolate] Envoi tâche FullDecrypt: ${task.taskId}');
    
    _sendPort!.send({
      'type': 'full_decrypt',
      'data': task.toJson(),
    });
    
    return completer.future;
  }
  
  /// Libère les ressources
  Future<void> dispose() async {
    _isDisposed = true;
    
    debugPrint('🛑 [CryptoIsolate] Arrêt de l\'Isolate...');
    
    // Annuler toutes les tâches en attente
    for (final completer in _pendingTasks.values) {
      completer.completeError(Exception('Service disposed'));
    }
    _pendingTasks.clear();
    _taskTypes.clear();
    
    if (_sendPort != null) {
      _sendPort!.send('dispose');
      _sendPort = null;
    }
    
    _resultSubscription?.cancel();
    _resultSubscription = null;
    
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    
    _resultPort?.close();
    _resultPort = null;
    
    debugPrint('✅ [CryptoIsolate] Isolate arrêté');
  }
}

