import 'package:socket_io_client/socket_io_client.dart' as IO;

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;

  late IO.Socket _socket;
  bool _isConnected = false;

  WebSocketService._internal();

  String _lastToken = '';

  void connect(String token) {
    if (_isConnected) return; 
    _lastToken = token; 

    _socket = IO.io('https://api.kavalek.fr', {
      'path': '/socket.io',
      'transports': ['websocket'],
      'auth': {'token': token},
    });

    _socket.onConnect((_) {
      print('✅ Connected to WebSocket server');
      _isConnected = true;
    });

    _socket.onDisconnect((_) {
      print('❌ Disconnected from WebSocket server');
      _isConnected = false;

      Future.delayed(const Duration(seconds: 3), () {
        print('🔄 Tentative de reconnexion...');
        connect(_lastToken); 
      });
    });

    _socket.onError((data) {
      print('❌ WebSocket Error: $data');
    });
  }

  void subscribeConversation(String conversationId) {
    _socket.emit('conversation:subscribe', conversationId);
  }

  void unsubscribeConversation(String conversationId) {
    _socket.emit('conversation:unsubscribe', conversationId);
  }

  void sendMessage(Map<String, dynamic> messagePayload) {
    _socket.emit('message:send', messagePayload);
  }

  void onNewMessage(Function(Map<String, dynamic>) callback) {
    _socket.on('message:new', (data) {
      callback(Map<String, dynamic>.from(data));
    });
  }

  void disconnect() {
    _socket.dispose();
    _isConnected = false;
  }

  void onError(Function(String) callback) {
    _socket.on('error', (data) {
      if (data is String) {
        callback(data);
      } else if (data is Map && data['error'] != null) {
        callback(data['error']);
      } else {
        callback('Erreur inconnue WebSocket');
      }
    });
  }
}
