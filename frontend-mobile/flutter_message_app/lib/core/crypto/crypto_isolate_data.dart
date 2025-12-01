import 'dart:typed_data';
import 'dart:convert';

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

