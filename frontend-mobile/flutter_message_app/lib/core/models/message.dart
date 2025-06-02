class Message {
  final String            id;
  final String            conversationId;
  final String            senderId;
  final String?           encrypted;
  final String?           iv;
  final Map<String, String> encryptedKeys;  // Clés AES chiffrées par destinataire
  final bool              signatureValid;
  final String?           senderPublicKey;
  final int               timestamp;

  // Texte déchiffré, mis en cache pour éviter plusieurs décryptions
  String?                  decryptedText;

  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.encrypted,
    this.iv,
    required this.encryptedKeys,
    required this.signatureValid,
    this.senderPublicKey,
    required this.timestamp,
    this.decryptedText,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    // Récupération des clés chiffrées par message
    final rawKeys = json['encrypted_keys'] as Map<String, dynamic>?;

    return Message(
      id:               json['id'] as String,
      conversationId:   json['conversationId'] as String,
      senderId:         json['senderId'] as String,
      encrypted:        json['encrypted'] as String?,
      iv:               json['iv'] as String?,
      encryptedKeys:    rawKeys != null
                         ? rawKeys.map((k, v) => MapEntry(k as String, v as String))
                         : <String, String>{},
      signatureValid:   json['signatureValid'] as bool,
      senderPublicKey:  json['senderPublicKey'] as String?,
      timestamp:        _parseInt(json['timestamp']),
    );
  }

  static int _parseInt(dynamic v) {
    if (v is int) return v;
    if (v is String && int.tryParse(v) != null) {
      return int.parse(v);
    }
    throw FormatException('Impossible de parser "\$v" en int');
  }
}
