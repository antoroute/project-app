class GroupInfo {
  final String groupId;
  final String name;
  final String creatorId;
  final DateTime createdAt;

  GroupInfo({
    required this.groupId,
    required this.name,
    required this.creatorId,
    required this.createdAt,
  });

  factory GroupInfo.fromJson(Map<String, dynamic> json) {
    return GroupInfo(
      groupId: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      creatorId: json['creator_id'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String? ?? DateTime.now().toIso8601String()),
    );
  }
}
