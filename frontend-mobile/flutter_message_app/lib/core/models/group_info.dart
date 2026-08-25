class GroupInfo {
  final String groupId;
  final String name;
  final String creatorId;
  final String role;
  final DateTime createdAt;

  GroupInfo({
    required this.groupId,
    required this.name,
    required this.creatorId,
    required this.role,
    required this.createdAt,
  });

  factory GroupInfo.fromJson(Map<String, dynamic> json) {
    return GroupInfo(
      groupId: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      creatorId: (json['creatorId'] ?? json['creator_id']) as String? ?? '',
      role: json['role'] as String? ?? 'member',
      createdAt: DateTime.parse(
        json['createdAt'] as String? ?? DateTime.now().toIso8601String(),
      ),
    );
  }
}
