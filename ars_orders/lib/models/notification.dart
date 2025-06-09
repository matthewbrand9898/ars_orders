// lib/models/notification.dart

class NotificationItem {
  final int id;
  final String message;
  final String? url;
  final DateTime createdAt;
  final String? senderId;

  NotificationItem({
    required this.id,
    required this.message,
    this.url,
    required this.createdAt,
    this.senderId,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> json) {
    return NotificationItem(
      id: json['id'] as int,
      message: json['message'] as String,
      url: json['url'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      senderId: (json['senderId'] as dynamic)?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'message': message,
      'url': url,
      'created_at': createdAt.toIso8601String(),
      'senderId': senderId,
    };
  }
}
