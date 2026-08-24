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
  final Map<String, Completer<Ed25519VerifyResult>> _pendingVerifyTasks = {};
  final Map<String, Completer<DecryptPipelineResult>> _pendingPipelineTasks =
      {};
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
          // 🔧 FIX: Vérifier d'abord le type de résultat en fonction des champs présents
          // Un résultat de pipeline a 'decryptedTextBytes', un résultat X25519 ECDH a 'sharedSecretBytes'
          final hasDecryptedText = message.containsKey('decryptedTextBytes');
          final hasSharedSecret = message.containsKey('sharedSecretBytes');
          final hasSignatureValid = message.containsKey('signatureValid');
          final isPipelineResult = hasDecryptedText;
          final isEcdhResult = hasSharedSecret;
          final isVerifyResult = hasSignatureValid;

          if (isVerifyResult) {
            final verifyCompleter = _pendingVerifyTasks.remove(taskId);
            if (verifyCompleter != null && !verifyCompleter.isCompleted) {
              if (message['error'] != null) {
                verifyCompleter.completeError(
                  Exception('Signature verification failed'),
                );
              } else {
                verifyCompleter.complete(Ed25519VerifyResult.fromJson(message));
              }
              return;
            }
          }

          // Traiter d'abord les résultats de pipeline (priorité car plus spécifique)
          if (isPipelineResult) {
            final pipelineCompleter = _pendingPipelineTasks.remove(taskId);
            if (pipelineCompleter != null && !pipelineCompleter.isCompleted) {
              if (message['error'] != null) {
                debugPrint(
                  '❌ [CryptoIsolate] Erreur pour pipeline $taskId: ${message['error']}',
                );
                pipelineCompleter.completeError(Exception(message['error']));
              } else {
                try {
                  final result = DecryptPipelineResult.fromJson(message);

                  // Validation : vérifier que le résultat contient bien les données
                  if (result.decryptedTextBytes == null &&
                      result.error == null) {
                    debugPrint(
                      '⚠️ [CryptoIsolate] Pipeline $taskId retourné sans données ni erreur',
                    );
                    pipelineCompleter.completeError(
                      Exception('Pipeline returned null decrypted text'),
                    );
                  } else {
                    pipelineCompleter.complete(result);
                  }
                } catch (e) {
                  debugPrint(
                    '❌ [CryptoIsolate] Erreur parsing résultat pipeline pour $taskId: $e',
                  );
                  pipelineCompleter.completeError(e);
                }
              }
              return;
            }
          }

          // Vérifier si c'est une tâche X25519 ECDH (seulement si ce n'est pas un résultat de pipeline)
          if (isEcdhResult) {
            final ecdhCompleter = _pendingTasks.remove(taskId);
            if (ecdhCompleter != null && !ecdhCompleter.isCompleted) {
              if (message['error'] != null) {
                debugPrint(
                  '❌ [CryptoIsolate] Erreur pour tâche $taskId: ${message['error']}',
                );
                ecdhCompleter.completeError(Exception(message['error']));
              } else {
                try {
                  ecdhCompleter.complete(X25519EcdhResult.fromJson(message));
                } catch (e) {
                  debugPrint(
                    '❌ [CryptoIsolate] Erreur parsing résultat pour $taskId: $e',
                  );
                  ecdhCompleter.completeError(e);
                }
              }
              return;
            }
          }

          // Ne pas afficher de warning si c'est un résultat tardif (peut arriver si timeout)
          // Seulement si c'est vraiment inattendu
          if (!_pendingTasks.containsKey(taskId) &&
              !_pendingVerifyTasks.containsKey(taskId) &&
              !_pendingPipelineTasks.containsKey(taskId)) {
            debugPrint(
              '⚠️ [CryptoIsolate] Aucun completer trouvé pour tâche: $taskId (probablement timeout ou déjà complété)',
            );
          }
        }
      }
    });

    // Attendre que le SendPort soit reçu (avec timeout)
    try {
      await _startupCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException(
            'Isolate startup timeout - SendPort not received',
          );
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
          completer.completeError(
            TimeoutException('X25519 ECDH task timeout after 60s'),
          );
        }
      }
    });

    debugPrint('📤 [CryptoIsolate] Envoi tâche X25519 ECDH: ${task.taskId}');

    _sendPort!.send({'type': 'x25519_ecdh', 'data': task.toJson()});

    return completer.future;
  }

  /// Vérifie une signature Ed25519 dans l'isolate crypto.
  Future<Ed25519VerifyResult> executeEd25519Verify(
    Ed25519VerifyTask task,
  ) async {
    await _ensureStarted();

    if (_isDisposed) {
      throw Exception('Service disposed');
    }

    final completer = Completer<Ed25519VerifyResult>();
    _pendingVerifyTasks[task.taskId] = completer;

    Timer(const Duration(seconds: 15), () {
      if (_pendingVerifyTasks.remove(task.taskId) != null &&
          !completer.isCompleted) {
        completer.completeError(
          TimeoutException('Ed25519 verification timeout'),
        );
      }
    });

    _sendPort!.send({'type': 'ed25519_verify', 'data': task.toJson()});

    return completer.future;
  }

  /// Exécute un pipeline complet de déchiffrement dans l'Isolate
  Future<DecryptPipelineResult> executeDecryptPipeline(
    DecryptPipelineTask task,
  ) async {
    await _ensureStarted();

    if (_isDisposed) {
      throw Exception('Service disposed');
    }

    final completer = Completer<DecryptPipelineResult>();
    _pendingPipelineTasks[task.taskId] = completer;

    // Timeout de sécurité (90 secondes - pipeline complet peut être lent)
    Timer(const Duration(seconds: 90), () {
      if (_pendingPipelineTasks.containsKey(task.taskId)) {
        _pendingPipelineTasks.remove(task.taskId);
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException('Decrypt pipeline task timeout after 90s'),
          );
        }
      }
    });

    debugPrint('📤 [CryptoIsolate] Envoi pipeline complet: ${task.taskId}');

    _sendPort!.send({'type': 'decrypt_pipeline', 'data': task.toJson()});

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

    for (final completer in _pendingVerifyTasks.values) {
      completer.completeError(Exception('Service disposed'));
    }
    _pendingVerifyTasks.clear();

    for (final completer in _pendingPipelineTasks.values) {
      completer.completeError(Exception('Service disposed'));
    }
    _pendingPipelineTasks.clear();

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
