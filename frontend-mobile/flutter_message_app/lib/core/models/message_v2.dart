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
  });

  factory MessageV2Model.fromJson(Map<String, dynamic> json) => MessageV2Model(
        v: json['v'] as int,
        alg: Map<String, String>.from(json['alg'] as Map),
        groupId: json['groupId'] as String,
        convId: json['convId'] as String,
        messageId: json['messageId'] as String,
        sentAt: (json['sentAt'] as num).toInt(),
        sender: Map<String, dynamic>.from(json['sender'] as Map),
        recipients: (json['recipients'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
        iv: json['iv'] as String,
        ciphertext: json['ciphertext'] as String,
        sig: json['sig'] as String,
      );

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
      };
}


