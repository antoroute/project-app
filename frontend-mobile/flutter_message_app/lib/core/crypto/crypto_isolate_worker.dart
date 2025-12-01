import 'dart:isolate';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'crypto_isolate_data.dart';

/// Fonction top-level pour l'Isolate worker
/// Exécute X25519 ECDH dans un Isolate séparé avec file de priorité
void cryptoWorker(SendPort mainSendPort) async {
  // Créer un port pour recevoir les messages du main
  final commandPort = ReceivePort();
  
  // Envoyer le SendPort du port de commande au main
  mainSendPort.send(commandPort.sendPort);
  
  // 🚀 OPTIMISATION: File de priorité pour traiter les messages visibles en premier
  final highPriorityQueue = <Map<String, dynamic>>[];
  final normalPriorityQueue = <Map<String, dynamic>>[];
  bool isProcessing = false;
  
  // Traiter la file de priorité
  Future<void> processQueue() async {
    if (isProcessing) return;
    isProcessing = true;
    
    while (highPriorityQueue.isNotEmpty || normalPriorityQueue.isNotEmpty) {
      Map<String, dynamic>? message;
      
      // Prioriser les tâches haute priorité
      if (highPriorityQueue.isNotEmpty) {
        message = highPriorityQueue.removeAt(0);
      } else if (normalPriorityQueue.isNotEmpty) {
        message = normalPriorityQueue.removeAt(0);
      }
      
      if (message == null) break;
      
      if (message['type'] == 'x25519_ecdh') {
        try {
          final taskData = message['data'] as Map<String, dynamic>;
          final task = X25519EcdhTask.fromJson(taskData);
          
          // Debug: Log dans l'Isolate (visible dans les logs Flutter)
          print('🔐 [CryptoIsolate] Traitement tâche X25519 ECDH: ${task.taskId} (priority: ${task.priority})');
          
          final result = await _processX25519Ecdh(task);
          
          // Envoyer le résultat sur le port principal (mainSendPort)
          mainSendPort.send(result.toJson());
          
          print('✅ [CryptoIsolate] Tâche ${task.taskId} terminée');
        } catch (e) {
          print('❌ [CryptoIsolate] Erreur tâche: $e');
          // Envoyer l'erreur sur le port principal
          final taskData = message['data'] as Map<String, dynamic>;
          mainSendPort.send({
            'taskId': taskData['taskId'] as String,
            'error': e.toString(),
          });
        }
      }
    }
    
    isProcessing = false;
  }
  
  // Écouter les messages de commande
  await for (final message in commandPort) {
      if (message is Map<String, dynamic> && message['type'] == 'x25519_ecdh') {
        // 🚀 OPTIMISATION: Ajouter à la file de priorité appropriée
        final taskData = message['data'] as Map<String, dynamic>;
        final priority = taskData['priority'] as int? ?? 0;
        
        if (priority == 1) {
          highPriorityQueue.add(message);
        } else {
          normalPriorityQueue.add(message);
        }
        
        // Traiter la file
        processQueue();
    } else if (message == 'dispose') {
      commandPort.close();
      break;
    } else {
      print('⚠️ [CryptoIsolate] Message inconnu reçu: $message');
    }
  }
}

/// Traite une tâche X25519 ECDH dans l'Isolate
Future<X25519EcdhResult> _processX25519Ecdh(X25519EcdhTask task) async {
  try {
    // 1. Reconstruire KeyPair depuis bytes (dans l'Isolate)
    final x = X25519();
    final myKeyPair = await x.newKeyPairFromSeed(task.myPrivateKeyBytes);
    final remotePub = SimplePublicKey(
      task.remotePublicKeyBytes,
      type: KeyPairType.x25519,
    );
    
    // 2. X25519 ECDH (dans l'Isolate - opération lourde)
    final shared = await x.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: remotePub,
    );
    
    // 3. Extraire les bytes du shared secret
    final sharedBytes = Uint8List.fromList(await shared.extractBytes());
    
    return X25519EcdhResult(
      taskId: task.taskId,
      sharedSecretBytes: sharedBytes,
    );
  } catch (e) {
    return X25519EcdhResult(
      taskId: task.taskId,
      error: e.toString(),
    );
  }
}

