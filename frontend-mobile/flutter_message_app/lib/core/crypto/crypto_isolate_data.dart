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

/// Données sérialisables pour un déchiffrement complet (sans cache)
/// Exécute toute la chaîne : X25519 ECDH -> HKDF -> AES unwrap -> AES decrypt
class FullDecryptTask {
  final String taskId;
  final String messageId;
  final String groupId;
  final String myUserId;
  final String myDeviceId;
  final String messageV2Json; // Map<String, dynamic> sérialisé en JSON
  final String myPrivateKeyBytesB64; // Uint8List en base64
  final int priority; // 0 = normal, 1 = haute priorité (messages visibles)
  
  FullDecryptTask({
    required this.taskId,
    required this.messageId,
    required this.groupId,
    required this.myUserId,
    required this.myDeviceId,
    required this.messageV2Json,
    required this.myPrivateKeyBytesB64,
    this.priority = 0,
  });
  
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'messageId': messageId,
    'groupId': groupId,
    'myUserId': myUserId,
    'myDeviceId': myDeviceId,
    'messageV2Json': messageV2Json,
    'myPrivateKeyBytesB64': myPrivateKeyBytesB64,
    'priority': priority,
  };
  
  factory FullDecryptTask.fromJson(Map<String, dynamic> json) => FullDecryptTask(
    taskId: json['taskId'] as String,
    messageId: json['messageId'] as String,
    groupId: json['groupId'] as String,
    myUserId: json['myUserId'] as String,
    myDeviceId: json['myDeviceId'] as String,
    messageV2Json: json['messageV2Json'] as String,
    myPrivateKeyBytesB64: json['myPrivateKeyBytesB64'] as String,
    priority: json['priority'] as int? ?? 0,
  );
}

/// Résultat d'un déchiffrement complet
class FullDecryptResult {
  final String taskId;
  final String? decryptedTextBytesB64; // Uint8List en base64
  final String? error;
  
  FullDecryptResult({
    required this.taskId,
    this.decryptedTextBytesB64,
    this.error,
  });
  
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'decryptedTextBytesB64': decryptedTextBytesB64,
    'error': error,
  };
  
  factory FullDecryptResult.fromJson(Map<String, dynamic> json) => FullDecryptResult(
    taskId: json['taskId'] as String,
    decryptedTextBytesB64: json['decryptedTextBytesB64'] as String?,
    error: json['error'] as String?,
  );
}

/// Données sérialisables pour un déchiffrement de contenu uniquement (avec cache)
/// Exécute seulement : AES decrypt content
class ContentDecryptTask {
  final String taskId;
  final String messageV2Json; // Map<String, dynamic> sérialisé en JSON
  final String mkBytesB64; // Uint8List en base64 (message key depuis le cache)
  final int priority; // 0 = normal, 1 = haute priorité (messages visibles)
  
  ContentDecryptTask({
    required this.taskId,
    required this.messageV2Json,
    required this.mkBytesB64,
    this.priority = 0,
  });
  
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'messageV2Json': messageV2Json,
    'mkBytesB64': mkBytesB64,
    'priority': priority,
  };
  
  factory ContentDecryptTask.fromJson(Map<String, dynamic> json) => ContentDecryptTask(
    taskId: json['taskId'] as String,
    messageV2Json: json['messageV2Json'] as String,
    mkBytesB64: json['mkBytesB64'] as String,
    priority: json['priority'] as int? ?? 0,
  );
}

/// Résultat d'un déchiffrement de contenu
class ContentDecryptResult {
  final String taskId;
  final String? decryptedTextBytesB64; // Uint8List en base64
  final String? error;
  
  ContentDecryptResult({
    required this.taskId,
    this.decryptedTextBytesB64,
    this.error,
  });
  
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'decryptedTextBytesB64': decryptedTextBytesB64,
    'error': error,
  };
  
  factory ContentDecryptResult.fromJson(Map<String, dynamic> json) => ContentDecryptResult(
    taskId: json['taskId'] as String,
    decryptedTextBytesB64: json['decryptedTextBytesB64'] as String?,
    error: json['error'] as String?,
  );
}

