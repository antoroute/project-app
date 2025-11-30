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
  final Map<String, Completer<X25519EcdhResult>> _pendingTasks = {};
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
          final completer = _pendingTasks.remove(taskId);
          if (completer != null && !completer.isCompleted) {
            if (message['error'] != null) {
              debugPrint('❌ [CryptoIsolate] Erreur pour tâche $taskId: ${message['error']}');
              completer.completeError(Exception(message['error']));
            } else {
              try {
                completer.complete(X25519EcdhResult.fromJson(message));
                debugPrint('✅ [CryptoIsolate] Tâche $taskId complétée avec succès');
              } catch (e) {
                debugPrint('❌ [CryptoIsolate] Erreur parsing résultat pour $taskId: $e');
                completer.completeError(e);
              }
            }
          } else {
            debugPrint('⚠️ [CryptoIsolate] Aucun completer trouvé pour tâche: $taskId');
          }
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
  
  /// Exécute une tâche X25519 ECDH dans l'Isolate
  Future<X25519EcdhResult> executeX25519Ecdh(X25519EcdhTask task) async {
    await _ensureStarted();
    
    if (_isDisposed) {
      throw Exception('Service disposed');
    }
    
    final completer = Completer<X25519EcdhResult>();
    _pendingTasks[task.taskId] = completer;
    
    // Timeout de sécurité (60 secondes - X25519 peut être lent sur mobile)
    Timer(const Duration(seconds: 60), () {
      if (_pendingTasks.containsKey(task.taskId)) {
        _pendingTasks.remove(task.taskId);
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
  
  /// Libère les ressources
  Future<void> dispose() async {
    _isDisposed = true;
    
    debugPrint('🛑 [CryptoIsolate] Arrêt de l\'Isolate...');
    
    // Annuler toutes les tâches en attente
    for (final completer in _pendingTasks.values) {
      completer.completeError(Exception('Service disposed'));
    }
    _pendingTasks.clear();
    
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

