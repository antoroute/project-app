class Conversation {
  final String conversationId;
  final String groupId;
  final String type;
  final String creatorId;
  final Map<String, String> encryptedSecrets; 
  final DateTime? lastReadAt;

  Conversation({
    required this.conversationId,
    required this.groupId,
    required this.type,
    required this.creatorId,
    required this.encryptedSecrets,
    this.lastReadAt,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final id = (json['conversationId'] ?? json['id']) as String? ?? '';
    final groupId = (json['groupId'] ?? json['group_id']) as String? ?? '';
    final type = (json['type'] as String? ?? 'subset');
    final creatorId = (json['creatorId'] ?? json['creator_id']) as String? ?? '';

    // On normalise encryptedSecrets en Map<String,String>
    final rawSecrets = json['encryptedSecrets'] ?? json['encrypted_secrets'];
    final Map<String, String> encryptedSecrets = <String, String>{};
    if (rawSecrets is Map) {
      rawSecrets.forEach((k, v) {
        if (v is String) encryptedSecrets[k as String] = v;
      });
    }

    DateTime? lastReadAt;
    final lastReadRaw = json['last_read_at'] ?? json['lastReadAt'];
    if (lastReadRaw != null) {
      lastReadAt = DateTime.parse(lastReadRaw as String);
    }

    return Conversation(
      conversationId: id,
      groupId: groupId,
      type: type,
      creatorId: creatorId,
      encryptedSecrets: encryptedSecrets,
      lastReadAt: lastReadAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id':             conversationId,
      'conversationId': conversationId,
      'groupId':        groupId,
      'type':           type,
      'creatorId':      creatorId,
      if (lastReadAt != null)
        'last_read_at': lastReadAt!.toIso8601String(),
      'encryptedSecrets': encryptedSecrets,
    };
  }
}
