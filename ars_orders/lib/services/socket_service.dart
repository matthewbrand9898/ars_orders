import 'package:ars_orders/services/api.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class SocketService {
  static final SocketService _instance = SocketService._();
  late IO.Socket socket;

  factory SocketService() => _instance;

  SocketService._() {
    socket = IO.io(
      getBaseUrl(),
      <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      },
    );
    socket.connect();
  }
}
