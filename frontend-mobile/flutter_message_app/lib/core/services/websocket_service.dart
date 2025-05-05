import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:async';

enum SocketStatus { disconnected, connecting, connected, error }

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;

  IO.Socket? _socket;
  SocketStatus _status = SocketStatus.disconnected;
  String _lastToken = '';
  String? _lastConversationId;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  static const int _maxReconnectAttempts = 5;
  static const Duration _baseReconnectDelay = Duration(seconds: 2);

  final Map<String, Function(dynamic)> _messageListeners = {};
  final StreamController<SocketStatus> _statusController = StreamController.broadcast();

  int _activeScreens = 0;

  WebSocketService._internal();

  SocketStatus get status => _status;
  Stream<SocketStatus> get statusStream => _statusController.stream;

  void screenAttached() => _activeScreens++;
  void screenDetached() {
    _activeScreens--;
    if (_activeScreens <= 0) {
      disconnect();
    }
  }

  void connect(String token, {String? conversationId}) {
    if (_status == SocketStatus.connected || _status == SocketStatus.connecting) return;

    _status = SocketStatus.connecting;
    _statusController.add(_status);
    _lastToken = token;
    _lastConversationId = conversationId;

    _disposeSocket();
    _log('Initialisation de la connexion WebSocket...', level: 'info');

    try {
      _socket = IO.io('https://api.kavalek.fr', {
        'path': '/socket.io',
        'transports': ['websocket', 'polling'],
        'auth': {'token': token},
      });

      _registerListeners();
      _socket!.connect();
    } catch (e) {
      _handleError("Erreur d'initialisation WebSocket: $e");
    }
  }

  void _registerListeners() {
    if (_socket == null) return;

    _socket!.onConnect((_) {
      _log('Connecté', level: 'info');
      _status = SocketStatus.connected;
      _statusController.add(_status);
      _reconnectAttempts = 0;
      if (_lastConversationId != null) {
        subscribeConversation(_lastConversationId!);
      }
    });

    _socket!.on('message:new', (message) {
      _log('Message reçu via WebSocket: $message');
      for (final cb in _messageListeners.values) {
        cb(message);
      }
    });

    _socket!.onDisconnect((_) {
      _log('Déconnecté', level: 'warn');
      _status = SocketStatus.disconnected;
      _statusController.add(_status);
      _tryReconnect();
    });

    _socket!.onError((data) => _handleError('Erreur WebSocket: $data'));
    _socket!.on('connect_error', (data) => _handleError('Erreur de connexion: $data'));
    _socket!.on('connect_timeout', (data) => _handleError('Timeout de connexion: $data'));
    _socket!.on('reconnect_failed', (_) => _handleError('Échec de reconnexion'));
    _socket!.on('reconnect', (_) => _log('Reconnecté', level: 'info'));
  }

  void _tryReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _log('Nombre maximal de tentatives de reconnexion atteint', level: 'error');
      return;
    }
    _reconnectAttempts++;
    final delay = _baseReconnectDelay * _reconnectAttempts;
    _log('Reconnexion dans ${delay.inSeconds}s...', level: 'warn');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => connect(_lastToken, conversationId: _lastConversationId));
  }

  void forceReconnect() {
    _log('Reconnexion forcée', level: 'info');
    disconnect();
    connect(_lastToken, conversationId: _lastConversationId);
  }

  void subscribeConversation(String conversationId) {
    if (_status == SocketStatus.connected && _socket != null) {
      _log('Abonnement à la conversation: $conversationId', level: 'info');
      _socket!.emit('conversation:subscribe', conversationId);
    }
  }

  void unsubscribeConversation(String conversationId) {
    if (_status == SocketStatus.connected && _socket != null) {
      _log('Désabonnement de la conversation: $conversationId', level: 'info');
      _socket!.emit('conversation:unsubscribe', conversationId);
    }
  }

  void sendMessage(Map<String, dynamic> messagePayload) {
    if (_status == SocketStatus.connected && _socket != null) {
      _log('Envoi message: $messagePayload', level: 'info');
      _socket!.emit('message:send', messagePayload);
    } else {
      _handleError('Socket non connectée, message non envoyé');
    }
  }

  void setOnNewMessageListener(String listenerId, Function(dynamic) callback) {
    _messageListeners[listenerId] = callback;
  }

  void removeOnNewMessageListener(String listenerId) {
    _messageListeners.remove(listenerId);
  }

  void disconnect() {
    _log('Déconnexion manuelle', level: 'info');
    _disposeSocket();
    _status = SocketStatus.disconnected;
    _statusController.add(_status);
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
  }

  void _disposeSocket() {
    if (_socket != null) {
      _socket!.clearListeners();
      _socket!.dispose();
      _socket = null;
    }
  }

  void _handleError(String message) {
    _log(message, level: 'error');
    _status = SocketStatus.error;
    _statusController.add(_status);
  }

  void _log(String message, {String level = 'debug'}) {
    final prefix = '[WebSocketService][$level]';
    print('$prefix $message');
  }
}
