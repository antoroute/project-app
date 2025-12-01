import 'dart:isolate';
import 'dart:typed_data';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'crypto_isolate_data.dart';

// Instances statiques pour les opérations crypto dans l'Isolate
final AesGcm _aead = AesGcm.with256bits();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// Fonction top-level pour l'Isolate worker
/// Exécute les opérations crypto dans un Isolate séparé avec file de priorité
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
      
      final messageType = message['type'] as String;
      
      if (messageType == 'x25519_ecdh') {
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
      } else if (messageType == 'content_decrypt') {
        try {
          final taskData = message['data'] as Map<String, dynamic>;
          final task = ContentDecryptTask.fromJson(taskData);
          
          print('🔐 [CryptoIsolate] Traitement tâche ContentDecrypt: ${task.taskId} (priority: ${task.priority})');
          
          final result = await _processContentDecrypt(task);
          
          mainSendPort.send(result.toJson());
          
          print('✅ [CryptoIsolate] Tâche ContentDecrypt ${task.taskId} terminée');
        } catch (e) {
          print('❌ [CryptoIsolate] Erreur ContentDecrypt: $e');
          final taskData = message['data'] as Map<String, dynamic>;
          mainSendPort.send({
            'taskId': taskData['taskId'] as String,
            'error': e.toString(),
          });
        }
      } else if (messageType == 'full_decrypt') {
        try {
          final taskData = message['data'] as Map<String, dynamic>;
          final task = FullDecryptTask.fromJson(taskData);
          
          print('🔐 [CryptoIsolate] Traitement tâche FullDecrypt: ${task.taskId} (priority: ${task.priority})');
          
          final result = await _processFullDecrypt(task);
          
          mainSendPort.send(result.toJson());
          
          print('✅ [CryptoIsolate] Tâche FullDecrypt ${task.taskId} terminée');
        } catch (e) {
          print('❌ [CryptoIsolate] Erreur FullDecrypt: $e');
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
      if (message is Map<String, dynamic>) {
        final messageType = message['type'] as String?;
        if (messageType == 'x25519_ecdh' || messageType == 'content_decrypt' || messageType == 'full_decrypt') {
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
        } else {
          print('⚠️ [CryptoIsolate] Type de message inconnu: $messageType');
        }
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

/// Nettoie et valide une chaîne Base64 (même logique que dans message_cipher_v2)
String _cleanBase64(String input) {
  // Supprimer les espaces, retours à la ligne et caractères invalides
  String cleaned = input.trim().replaceAll(RegExp(r'[\s\n\r]'), '');
  
  // Vérifier que la chaîne ne contient que des caractères Base64 valides
  if (!RegExp(r'^[A-Za-z0-9+/=_-]*$').hasMatch(cleaned)) {
    throw FormatException('Invalid Base64 characters in: $input');
  }
  
  // Gérer les variantes Base64 URL-safe
  cleaned = cleaned.replaceAll('-', '+').replaceAll('_', '/');
  
  // Ajouter padding si nécessaire
  while (cleaned.length % 4 != 0) {
    cleaned += '=';
  }
  
  return cleaned;
}

/// Traite un déchiffrement de contenu uniquement (avec cache)
Future<ContentDecryptResult> _processContentDecrypt(ContentDecryptTask task) async {
  try {
    // 1. Désérialiser messageV2
    final messageV2 = jsonDecode(task.messageV2Json) as Map<String, dynamic>;
    
    // 2. Désérialiser mkBytes depuis base64
    final mkBytes = base64Decode(task.mkBytesB64);
    
    // 3. Déchiffrer le contenu avec AES-GCM
    final ivB64 = messageV2['iv'] as String;
    final ctB64 = messageV2['ciphertext'] as String;
    
    // Validation et nettoyage Base64
    final iv = base64.decode(_cleanBase64(ivB64));
    final ct = base64.decode(_cleanBase64(ctB64));
    final macLen = 16;
    
    // Validation pour éviter RangeError
    if (ct.length < macLen) {
      throw Exception('Ciphertext trop court: ${ct.length} < $macLen');
    }
    
    final ctLen = ct.length - macLen;
    if (ctLen < 0) {
      throw Exception('Longueur ciphertext invalide: $ctLen');
    }
    
    final contentBox = SecretBox(
      ct.sublist(0, ctLen),
      nonce: iv,
      mac: Mac(ct.sublist(ctLen)),
    );
    
    final clear = await _aead.decrypt(
      contentBox,
      secretKey: SecretKey(mkBytes),
    );
    
    final decryptedBytes = Uint8List.fromList(clear);
    
    return ContentDecryptResult(
      taskId: task.taskId,
      decryptedTextBytesB64: base64Encode(decryptedBytes),
    );
  } catch (e) {
    return ContentDecryptResult(
      taskId: task.taskId,
      error: e.toString(),
    );
  }
}

/// Traite un déchiffrement complet (sans cache)
/// Pipeline: X25519 ECDH -> HKDF -> AES unwrap -> AES decrypt
Future<FullDecryptResult> _processFullDecrypt(FullDecryptTask task) async {
  try {
    // 1. Désérialiser messageV2
    final messageV2 = jsonDecode(task.messageV2Json) as Map<String, dynamic>;
    
    // 2. Désérialiser myPrivateKeyBytes
    final myPrivateKeyBytes = base64Decode(task.myPrivateKeyBytesB64);
    
    // 3. Récupérer l'eph_pub depuis le sender
    final sender = messageV2['sender'] as Map<String, dynamic>;
    final ephPubB64 = sender['eph_pub'] as String;
    
    if (ephPubB64.isEmpty) {
      throw Exception('sender.eph_pub is empty in messageV2');
    }
    
    final remotePublicKeyBytes = base64.decode(_cleanBase64(ephPubB64));
    
    // 4. X25519 ECDH
    final x = X25519();
    final myKeyPair = await x.newKeyPairFromSeed(myPrivateKeyBytes);
    final remotePub = SimplePublicKey(
      remotePublicKeyBytes,
      type: KeyPairType.x25519,
    );
    
    final shared = await x.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: remotePub,
    );
    
    final sharedBytes = Uint8List.fromList(await shared.extractBytes());
    final sharedSecret = SecretKey(sharedBytes);
    
    // 5. Récupérer la salt depuis le payload
    if (!messageV2.containsKey('salt')) {
      throw Exception('salt is required in messageV2');
    }
    final salt = base64.decode(_cleanBase64(messageV2['salt'] as String));
    
    // 6. HKDF pour dériver KEK
    final infoData = 'project-app/v2 ${task.groupId} ${messageV2['convId']} ${task.myUserId} ${task.myDeviceId}';
    final kek = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: salt,
      info: utf8.encode(infoData),
    );
    final kekBytes = Uint8List.fromList(await kek.extractBytes());
    
    // 7. Récupérer les recipients et trouver le nôtre
    final recipients = messageV2['recipients'] as List<dynamic>;
    if (recipients.isEmpty) {
      throw Exception('No recipients found in messageV2');
    }
    
    Map<String, dynamic>? mine;
    for (final r in recipients) {
      final m = r as Map<String, dynamic>;
      if (m['userId'] == task.myUserId && m['deviceId'] == task.myDeviceId) {
        mine = m;
        break;
      }
    }
    
    if (mine == null) {
      throw Exception('No wrap for this device');
    }
    
    // 8. AES-GCM unwrap pour obtenir mkBytes
    final wrapBytes = base64.decode(_cleanBase64(mine['wrap'] as String));
    final wrapNonce = base64.decode(_cleanBase64(mine['nonce'] as String));
    final macLen = 16;
    
    if (wrapBytes.length < macLen) {
      throw Exception('Wrap bytes trop courts: ${wrapBytes.length} < $macLen');
    }
    
    final cipherLen = wrapBytes.length - macLen;
    if (cipherLen < 0) {
      throw Exception('Longueur cipher invalide: $cipherLen');
    }
    
    final wrapBox = SecretBox(
      wrapBytes.sublist(0, cipherLen),
      nonce: wrapNonce,
      mac: Mac(wrapBytes.sublist(cipherLen)),
    );
    
    final mkBytes = await _aead.decrypt(
      wrapBox,
      secretKey: SecretKey(kekBytes),
    );
    
    // 9. AES-GCM decrypt content
    final ivB64 = messageV2['iv'] as String;
    final ctB64 = messageV2['ciphertext'] as String;
    
    final iv = base64.decode(_cleanBase64(ivB64));
    final ct = base64.decode(_cleanBase64(ctB64));
    final macLen2 = 16;
    
    if (ct.length < macLen2) {
      throw Exception('Ciphertext trop court: ${ct.length} < $macLen2');
    }
    
    final ctLen = ct.length - macLen2;
    if (ctLen < 0) {
      throw Exception('Longueur ciphertext invalide: $ctLen');
    }
    
    final contentBox = SecretBox(
      ct.sublist(0, ctLen),
      nonce: iv,
      mac: Mac(ct.sublist(ctLen)),
    );
    
    final clear = await _aead.decrypt(
      contentBox,
      secretKey: SecretKey(Uint8List.fromList(mkBytes)),
    );
    
    final decryptedBytes = Uint8List.fromList(clear);
    
    return FullDecryptResult(
      taskId: task.taskId,
      decryptedTextBytesB64: base64Encode(decryptedBytes),
    );
  } catch (e) {
    return FullDecryptResult(
      taskId: task.taskId,
      error: e.toString(),
    );
  }
}

