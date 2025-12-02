import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Données sérialisables pour une tâche X25519 ECDH dans un Isolate
class X25519EcdhTask {
  final String taskId;
  final Uint8List myPrivateKeyBytes; // Seed X25519 (32 bytes)
  final Uint8List remotePublicKeyBytes; // eph_pub (32 bytes)
  final int priority; // 0 = normal, 1 = haute priorité (messages visibles)
  
  X25519EcdhTask({
    required this.taskId,
    required this.myPrivateKeyBytes,
    required this.remotePublicKeyBytes,
    this.priority = 0,
  });
  
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'myPrivateKeyBytes': base64Encode(myPrivateKeyBytes),
    'remotePublicKeyBytes': base64Encode(remotePublicKeyBytes),
    'priority': priority,
  };
  
  factory X25519EcdhTask.fromJson(Map<String, dynamic> json) => X25519EcdhTask(
    taskId: json['taskId'] as String,
    myPrivateKeyBytes: base64Decode(json['myPrivateKeyBytes'] as String),
    remotePublicKeyBytes: base64Decode(json['remotePublicKeyBytes'] as String),
    priority: json['priority'] as int? ?? 0,
  );
}

/// Résultat de X25519 ECDH
class X25519EcdhResult {
  final String taskId;
  final Uint8List? sharedSecretBytes; // 32 bytes
  final String? error;
  
  X25519EcdhResult({
    required this.taskId,
    this.sharedSecretBytes,
    this.error,
  });
  
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'sharedSecretBytes': sharedSecretBytes != null ? base64Encode(sharedSecretBytes!) : null,
    'error': error,
  };
  
  factory X25519EcdhResult.fromJson(Map<String, dynamic> json) => X25519EcdhResult(
    taskId: json['taskId'] as String,
    sharedSecretBytes: json['sharedSecretBytes'] != null 
      ? base64Decode(json['sharedSecretBytes'] as String)
      : null,
    error: json['error'] as String?,
  );
}

/// Tâche pour le pipeline complet de déchiffrement dans l'Isolate
class DecryptPipelineTask {
  final String taskId;
  final int priority; // 0 = normal, 1 = haute priorité
  final Uint8List myPrivateKeyBytes; // 32 bytes (seed X25519)
  final Uint8List remotePublicKeyBytes; // 32 bytes (eph_pub)
  
  // Données pour HKDF
  final String groupId;
  final String convId;
  final String myUserId;
  final String myDeviceId;
  final Uint8List salt; // 16 bytes
  
  // Données pour AES-GCM Unwrap
  final Uint8List wrapBytes; // wrap chiffré
  final Uint8List wrapNonce; // 12 bytes
  
  // Données pour AES-GCM Decrypt
  final Uint8List iv; // 12 bytes
  final Uint8List ciphertext; // contenu chiffré
  
  DecryptPipelineTask({
    required this.taskId,
    this.priority = 0,
    required this.myPrivateKeyBytes,
    required this.remotePublicKeyBytes,
    required this.groupId,
    required this.convId,
    required this.myUserId,
    required this.myDeviceId,
    required this.salt,
    required this.wrapBytes,
    required this.wrapNonce,
    required this.iv,
    required this.ciphertext,
  });
  
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'priority': priority,
    'myPrivateKeyBytes': base64Encode(myPrivateKeyBytes),
    'remotePublicKeyBytes': base64Encode(remotePublicKeyBytes),
    'groupId': groupId,
    'convId': convId,
    'myUserId': myUserId,
    'myDeviceId': myDeviceId,
    'salt': base64Encode(salt),
    'wrapBytes': base64Encode(wrapBytes),
    'wrapNonce': base64Encode(wrapNonce),
    'iv': base64Encode(iv),
    'ciphertext': base64Encode(ciphertext),
  };
  
  factory DecryptPipelineTask.fromJson(Map<String, dynamic> json) => DecryptPipelineTask(
    taskId: json['taskId'] as String,
    priority: json['priority'] as int? ?? 0,
    myPrivateKeyBytes: base64Decode(json['myPrivateKeyBytes'] as String),
    remotePublicKeyBytes: base64Decode(json['remotePublicKeyBytes'] as String),
    groupId: json['groupId'] as String,
    convId: json['convId'] as String,
    myUserId: json['myUserId'] as String,
    myDeviceId: json['myDeviceId'] as String,
    salt: base64Decode(json['salt'] as String),
    wrapBytes: base64Decode(json['wrapBytes'] as String),
    wrapNonce: base64Decode(json['wrapNonce'] as String),
    iv: base64Decode(json['iv'] as String),
    ciphertext: base64Decode(json['ciphertext'] as String),
  );
}

/// Résultat du pipeline complet de déchiffrement depuis l'Isolate
class DecryptPipelineResult {
  final String taskId;
  final Uint8List? decryptedTextBytes; // Texte déchiffré (null si erreur)
  final String? error; // Message d'erreur (null si succès)
  
  DecryptPipelineResult({
    required this.taskId,
    this.decryptedTextBytes,
    this.error,
  });
  
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'decryptedTextBytes': decryptedTextBytes != null 
        ? base64Encode(decryptedTextBytes!) 
        : null,
    'error': error,
  };
  
  factory DecryptPipelineResult.fromJson(Map<String, dynamic> json) {
    try {
      final taskId = json['taskId'] as String;
      Uint8List? decryptedTextBytes;
      
      if (json['decryptedTextBytes'] != null) {
        try {
          final base64Str = json['decryptedTextBytes'] as String;
          decryptedTextBytes = base64Decode(base64Str);
        } catch (e) {
          debugPrint('❌ [DecryptPipelineResult] Erreur base64Decode: $e');
          rethrow;
        }
      }
      
      final error = json['error'] as String?;
      
      return DecryptPipelineResult(
        taskId: taskId,
        decryptedTextBytes: decryptedTextBytes,
        error: error,
      );
    } catch (e) {
      debugPrint('❌ [DecryptPipelineResult] Erreur fromJson: $e');
      rethrow;
    }
  }
}

