import 'package:socket_io_client/socket_io_client.dart' as IO;

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;

  late IO.Socket _socket;
  bool _isConnected = false;
  String _lastToken = '';

  WebSocketService._internal();

  void connect(String token, {String? conversationId}) {
    if (_isConnected) return;
    _lastToken = token;

    _socket = IO.io('https://api.kavalek.fr', {
      'path': '/socket.io',
      'transports': ['websocket'],
      'auth': {'token': token},
    });

    _socket.onConnect((_) {
      print('✅ WebSocket connecté');
      _isConnected = true;

      if (conversationId != null) {
        subscribeConversation(conversationId);
      }
    });

    _socket.onDisconnect((_) {
      print('❌ WebSocket déconnecté');
      _isConnected = false;
      Future.delayed(const Duration(seconds: 3), () => reconnect());
    });

    _socket.onError((data) {
      print('❌ WebSocket erreur: $data');
    });
  }

  void reconnect() {
    if (_lastToken.isNotEmpty) {
      connect(_lastToken);
    }
  }

  void subscribeConversation(String conversationId) {
    if (_isConnected) {
      _socket.emit('conversation:subscribe', conversationId);
    }
  }

  void unsubscribeConversation(String conversationId) {
    if (_isConnected) {
      _socket.emit('conversation:unsubscribe', conversationId);
    }
  }

  void sendMessage(Map<String, dynamic> messagePayload) {
    if (_isConnected) {
      _socket.emit('message:send', messagePayload);
    }
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
