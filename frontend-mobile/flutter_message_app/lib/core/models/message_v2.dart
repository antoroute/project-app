class MessageV2Model {
  final int v;
  final Map<String, String> alg;
  final String groupId;
  final String convId;
  final String messageId;
  final int sentAt;
  final Map<String, dynamic> sender;
  final List<Map<String, dynamic>> recipients;
  final String iv;
  final String ciphertext;
  final String sig;
  final String salt;

  MessageV2Model({
    required this.v,
    required this.alg,
    required this.groupId,
    required this.convId,
    required this.messageId,
    required this.sentAt,
    required this.sender,
    required this.recipients,
    required this.iv,
    required this.ciphertext,
    required this.sig,
    required this.salt,
  });

  factory MessageV2Model.fromJson(Map<String, dynamic> json) {
    // Adapter à la structure backend qui retourne senderUserId/senderDeviceId directement
    // au lieu d'un objet sender
    Map<String, dynamic> senderObject;
    if (json.containsKey('sender')) {
      senderObject = Map<String, dynamic>.from(json['sender'] as Map);
    } else {
      // Construction depuis les champs backend
      senderObject = {
        'userId': json['senderUserId'] as String? ?? '',
        'deviceId': json['senderDeviceId'] as String? ?? '',
        'eph_pub': json['sender_eph_pub'] as String? ?? '',
        'key_version': 1,
      };
    }
    
    return MessageV2Model(
      v: json['v'] as int,
      alg: Map<String, String>.from(json['alg'] as Map),
      groupId: json['groupId'] as String? ?? '',
      convId: json['convId'] as String,
      messageId: json['messageId'] as String,
      sentAt: _parseInt(json['sentAt']),
      sender: senderObject,
      recipients: (json['recipients'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
      iv: json['iv'] as String,
      ciphertext: json['ciphertext'] as String,
      sig: json['sig'] as String,
      salt: json['salt'] as String? ?? '',
    );
  }

  static int _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  Map<String, dynamic> toJson() => {
        'v': v,
        'alg': alg,
        'groupId': groupId,
        'convId': convId,
        'messageId': messageId,
        'sentAt': sentAt,
        'sender': sender,
        'recipients': recipients,
        'iv': iv,
        'ciphertext': ciphertext,
        'sig': sig,
        'salt': salt,
      };
}


