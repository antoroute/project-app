import 'dart:isolate';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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
          final result = await _processX25519Ecdh(task);
          
          // Envoyer le résultat sur le port principal (mainSendPort)
          mainSendPort.send(result.toJson());
        } catch (e) {
          debugPrint('❌ [CryptoIsolate] Erreur tâche X25519 ECDH: $e');
          // Envoyer l'erreur sur le port principal
          final taskData = message['data'] as Map<String, dynamic>;
          mainSendPort.send({
            'taskId': taskData['taskId'] as String,
            'error': e.toString(),
          });
        }
      } else if (message['type'] == 'decrypt_pipeline') {
        try {
          final taskData = message['data'] as Map<String, dynamic>;
          final task = DecryptPipelineTask.fromJson(taskData);
          
          final result = await _processDecryptPipeline(task);
          
          // Validation avant envoi
          final resultJson = result.toJson();
          
          if (resultJson['decryptedTextBytes'] == null && resultJson['error'] == null) {
            debugPrint('❌ [CryptoIsolate] Pipeline ${task.taskId} retourne un résultat invalide (null sans erreur)');
            // Forcer une erreur si le résultat est invalide
            mainSendPort.send({
              'taskId': task.taskId,
              'error': 'Pipeline returned invalid result: no data and no error',
            });
          } else {
            mainSendPort.send(resultJson);
            if (result.error != null) {
              debugPrint('❌ [CryptoIsolate] Pipeline ${task.taskId} terminé avec erreur: ${result.error}');
            }
          }
        } catch (e) {
          debugPrint('❌ [CryptoIsolate] Erreur pipeline: $e');
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
      if (message is Map<String, dynamic> && 
          (message['type'] == 'x25519_ecdh' || message['type'] == 'decrypt_pipeline')) {
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
      debugPrint('⚠️ [CryptoIsolate] Message inconnu reçu: $message');
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

/// Traite un pipeline complet de déchiffrement dans l'Isolate
Future<DecryptPipelineResult> _processDecryptPipeline(DecryptPipelineTask task) async {
  try {
    // 1. X25519 ECDH
    final x = X25519();
    final myKeyPair = await x.newKeyPairFromSeed(task.myPrivateKeyBytes);
    final remotePub = SimplePublicKey(
      task.remotePublicKeyBytes,
      type: KeyPairType.x25519,
    );
    final shared = await x.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: remotePub,
    );
    final sharedBytes = Uint8List.fromList(await shared.extractBytes());
    
    // Validation : X25519 doit retourner 32 bytes
    if (sharedBytes.isEmpty || sharedBytes.length != 32) {
      throw Exception('X25519 ECDH returned invalid shared secret: ${sharedBytes.length} bytes (expected 32)');
    }
    
    // 2. HKDF
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final infoData = 'project-app/v2 ${task.groupId} ${task.convId} ${task.myUserId} ${task.myDeviceId}';
    final kek = await hkdf.deriveKey(
      secretKey: SecretKey(sharedBytes),
      nonce: task.salt,
      info: utf8.encode(infoData),
    );
    final kekBytes = Uint8List.fromList(await kek.extractBytes());
    
    // 3. AES-GCM Unwrap
    final aead = AesGcm.with256bits();
    final macLen = 16;
    
    // Validation pour éviter RangeError
    if (task.wrapBytes.length < macLen) {
      throw Exception('Wrap bytes trop courts: ${task.wrapBytes.length} < $macLen');
    }
    
    final cipherLen = task.wrapBytes.length - macLen;
    if (cipherLen < 0) {
      throw Exception('Longueur cipher invalide: $cipherLen');
    }
    
    final wrapBox = SecretBox(
      task.wrapBytes.sublist(0, cipherLen),
      nonce: task.wrapNonce,
      mac: Mac(task.wrapBytes.sublist(cipherLen)),
    );
    final mkBytes = await aead.decrypt(
      wrapBox,
      secretKey: SecretKey(kekBytes),
    );
    final mkBytesList = Uint8List.fromList(mkBytes);
    
    // 4. AES-GCM Decrypt Content
    final macLen2 = 16;
    
    // Validation pour éviter RangeError
    if (task.ciphertext.length < macLen2) {
      throw Exception('Ciphertext trop court: ${task.ciphertext.length} < $macLen2');
    }
    
    final ctLen = task.ciphertext.length - macLen2;
    if (ctLen < 0) {
      throw Exception('Longueur ciphertext invalide: $ctLen');
    }
    
    final contentBox = SecretBox(
      task.ciphertext.sublist(0, ctLen),
      nonce: task.iv,
      mac: Mac(task.ciphertext.sublist(ctLen)),
    );
    final decryptedContent = await aead.decrypt(
      contentBox,
      secretKey: SecretKey(mkBytesList),
    );
    
    final decryptedBytes = Uint8List.fromList(decryptedContent);
    
    // Validation : s'assurer que le résultat n'est pas vide
    if (decryptedBytes.isEmpty) {
      throw Exception('Déchiffrement réussi mais résultat vide');
    }
    
    return DecryptPipelineResult(
      taskId: task.taskId,
      decryptedTextBytes: decryptedBytes,
    );
  } catch (e, stackTrace) {
    debugPrint('❌ [CryptoIsolate] Erreur dans pipeline ${task.taskId}: $e');
    return DecryptPipelineResult(
      taskId: task.taskId,
      error: 'Pipeline error: ${e.toString()}',
    );
  }
}

