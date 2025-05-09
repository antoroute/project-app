import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_message_app/core/providers/auth_provider.dart';

enum SocketStatus { disconnected, connecting, connected, error }

class WebSocketService {
  WebSocketService._internal();
  static final WebSocketService instance = WebSocketService._internal();

  IO.Socket? _socket;
  SocketStatus _status = SocketStatus.disconnected;
  String? _lastConversationId;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  int _activeScreens = 0;

  static const int _maxReconnectAttempts = 5;
  static const Duration _baseReconnectDelay = Duration(seconds: 2);

  final Map<String, Function(dynamic)> _messageListeners = {};
  final StreamController<SocketStatus> _statusController = StreamController.broadcast();

  SocketStatus get status => _status;
  Stream<SocketStatus> get statusStream => _statusController.stream;

  void screenAttached() => _activeScreens++;

  void screenDetached() {
    _activeScreens--;
    if (_activeScreens <= 0) {
      disconnect();
    }
  }

    /// Connecte la socket, vérifie et rafraîchit le token si nécessaire
  Future<void> connect(BuildContext context, {String? conversationId}) async {
    if (_status == SocketStatus.connected || _status == SocketStatus.connecting) return;
    _status = SocketStatus.connecting;
    _statusController.add(_status);
    _lastConversationId = conversationId;

    // Validation du JWT
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final valid = await auth.ensureTokenValid();
    if (!valid) {
      _handleError('Token invalide ou rafraîchissement échoué.');
      return;
    }
    final token = auth.token!;

    // Initialisation de la connexion WebSocket
    _disposeSocket();
    _log('Initialisation de la connexion WebSocket...', level: 'info');
    try {
      _socket = IO.io(
        'https://api.kavalek.fr',
        IO.OptionBuilder()
            .setPath('/socket.io')
            .setTransports(['websocket'])
            .setAuth({'token': token})
            .disableAutoConnect()
            .build(),
      );
      _registerListeners(context);
      _socket!.connect();
    } catch (e) {
      _handleError("Erreur d'initialisation WebSocket: $e");
    }
  }

  void _registerListeners(BuildContext context) {
    if (_socket == null) return;
    _socket!.onConnect((_) {
      _log('WebSocket connecté', level: 'info');
      _status = SocketStatus.connected;
      _statusController.add(_status);
      _reconnectAttempts = 0;
      if (_lastConversationId != null) {
        subscribeConversation(_lastConversationId!);
      }
    });

    _socket!.onDisconnect((_) {
      _log('WebSocket déconnecté', level: 'warn');
      _status = SocketStatus.disconnected;
      _statusController.add(_status);
      _tryReconnect(context);
    });

    _socket!.on('message:new', (data) {
      _messageListeners.values.forEach((cb) => cb(data));
    });

    _socket!.onError((data) => _handleError('Erreur WebSocket: $data'));

    _socket!.on('connect_error', (data) => _handleError('Erreur de connexion: $data'));

    _socket!.on('connect_timeout', (data) => _handleError('Timeout de connexion: $data'));

    _socket!.on('reconnect_failed', (_) => _handleError('Échec de reconnexion'));

    _socket!.onReconnecting((_) {
      _log('Reconnexion en cours...', level: 'warn');
    });

    _socket!.onReconnect((_) {
      _log('Reconnecté', level: 'info');
    });
  }

  void _tryReconnect(BuildContext context) {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _handleError('Échec de reconnexion après plusieurs tentatives');
      return;
    }
    _reconnectAttempts++;
    final delay = _baseReconnectDelay * _reconnectAttempts;
    _log('Tentative de reconnexion dans ${delay.inSeconds}s', level: 'warn');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => connect(context, conversationId: _lastConversationId));
  }

  void forceReconnect(BuildContext context) {
    _log('Reconnexion forcée', level: 'info');
    disconnect();
    connect(context, conversationId: _lastConversationId);
  }

  void subscribeConversation(String conversationId) {
    if (_status == SocketStatus.connected) {
      _log('Abonnement à la conversation: $conversationId', level: 'info');
      _socket?.emit('conversation:subscribe', conversationId);
    }
  }

  void unsubscribeConversation(String conversationId) {
    if (_status == SocketStatus.connected) {
      _log('Désabonnement de la conversation: $conversationId', level: 'info');
      _socket?.emit('conversation:unsubscribe', conversationId);
    }
  }

  void sendMessage(dynamic payload) {
    if (_status == SocketStatus.connected) {
      _log('Envoi message: $payload', level: 'info');
      _socket?.emit('message:send', payload);
    } else {
      _handleError('Socket non connectée, message non envoyé');
    }
  }

  void setOnNewMessageListener(String id, Function(dynamic) callback) {
    _messageListeners[id] = callback;
  }

  void removeOnNewMessageListener(String id) {
    _messageListeners.remove(id);
  }

  void disconnect() {
    _log('Déconnexion manuelle', level: 'info');
    _disposeSocket();
    _status = SocketStatus.disconnected;
    _statusController.add(_status);
    _reconnectTimer?.cancel();
  }

  void _disposeSocket() {
    _socket?..clearListeners();
    _socket?.dispose();
    _socket = null;
  }

  void _handleError(String msg) {
    _log(msg, level: 'error');
    _status = SocketStatus.error;
    _statusController.add(_status);
  }

  void _log(String message, {String level = 'info'}) {
    print('[WebSocketService][$level] $message');
  }
}
