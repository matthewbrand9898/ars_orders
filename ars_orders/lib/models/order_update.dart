class OrderUpdate {
  final int id;
  final String text;
  final String username;
  final DateTime createdAt;

  OrderUpdate({
    required this.id,
    required this.text,
    required this.username,
    required this.createdAt,
  });

  factory OrderUpdate.fromJson(Map<String, dynamic> j) => OrderUpdate(
        id: j['id'],
        text: j['text'],
        username: j['username'], // ← parse it here
        createdAt: DateTime.parse(j['created_at']).toLocal(),
      );
}
