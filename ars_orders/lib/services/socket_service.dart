import 'dart:async';
import 'dart:convert';

import 'package:ars_orders/services/api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:ars_orders/models/notification.dart';
import 'package:audioplayers/audioplayers.dart';

class SocketService {
  static final SocketService _instance = SocketService._();
  late IO.Socket socket;

  final AudioPlayer _audioPlayer = AudioPlayer();

  // ① A private StreamController that emits NotificationItem
  final StreamController<NotificationItem> _notifController =
      StreamController.broadcast();

  // Expose the broadcast stream so multiple widgets can listen
  Stream<NotificationItem> get onNewNotificationStream =>
      _notifController.stream;

  factory SocketService() => _instance;
  String? _username;

  Map<String, dynamic> decodeJwtPayload(String token) {
    final parts = token.split('.');
    if (parts.length != 3) throw Exception('Invalid JWT');
    final payload = parts[1];
    final normalized = base64Url.normalize(payload);
    final decoded = utf8.decode(base64Url.decode(normalized));
    return json.decode(decoded) as Map<String, dynamic>;
  }

  Future<void> _loadUsernameFromToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt');
    if (token != null) {
      final payload = decodeJwtPayload(token);

      _username = payload['username'] as String?;
    }
  }

  void playNotificationSound() {
    // On Web, load via UrlSource; on mobile, use AssetSource.

    // Relative URL to the asset folder is fine in a Flutter web build.
    _audioPlayer.play(
      UrlSource('assets/sounds/notificationSound.wav'),
    );
  }

  SocketService._() {
    socket = IO.io(
      getBaseUrl(),
      <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      },
    );

    socket.on('new_notification', (data) async {
      final notif =
          NotificationItem.fromJson(Map<String, dynamic>.from(data as Map));
      await _loadUsernameFromToken();
      if (_username == notif.senderId) {
        return;
      }
      // play sound (skip your own logic here if needed)
      _audioPlayer.play(UrlSource('assets/sounds/notificationSound.wav'));
      // ② Add the incoming notification to the broadcast stream
      _notifController.add(notif);
    });

    socket.connect();
  }
  void dispose() {
    _notifController.close();
    _audioPlayer.dispose();
  }
}
