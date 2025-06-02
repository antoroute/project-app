import 'dart:async';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/models/message.dart';
import 'package:flutter_message_app/core/services/api_service.dart';
import 'package:provider/provider.dart';

enum SocketStatus { disconnected, connecting, connected, error }

class WebSocketService {
  WebSocketService._internal();
  static final WebSocketService instance = WebSocketService._internal();

  IO.Socket? _socket;
  SocketStatus _status = SocketStatus.disconnected;
  final StreamController<SocketStatus> _statusController = StreamController.broadcast();

  SocketStatus get status => _status;
  Stream<SocketStatus> get statusStream => _statusController.stream;

  /// Callbacks à brancher depuis vos providers
  void Function(Message message)? onNewMessage;
  void Function(String conversationId, String userId)? onUserAdded;
  VoidCallback? onNotificationNew;
  VoidCallback? onConversationJoined;
  VoidCallback? onGroupJoined;

  /// Établit la connexion WS
  Future<void> connect(BuildContext context) async {
    if (_status == SocketStatus.connected || _status == SocketStatus.connecting) return;
    _updateStatus(SocketStatus.connecting);

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final valid = await auth.ensureTokenValid();
    if (!valid) {
      _handleError('Token invalide ou rafraîchissement échoué.');
      return;
    }
    final token = auth.token!;
    _disposeSocket();

    try {
      _socket = IO.io(
        'https://api.kavalek.fr',
        IO.OptionBuilder()
            .setPath('/socket.io')
            .setTransports(['websocket'])
            .setAuth({'token': token})
            .build(),
      );
      _registerListeners(context);
      _socket!.connect();
    } catch (e) {
      _handleError("Erreur d'initialisation du WebSocket: $e");
    }
  }

  void _registerListeners(BuildContext context) {
    if (_socket == null) return;

    _socket!
      ..onConnect((_) {
        _log('WebSocket connecté', level: 'info');
        _updateStatus(SocketStatus.connected);
      })
      ..onDisconnect((_) {
        _log('WebSocket déconnecté', level: 'warn');
        _updateStatus(SocketStatus.disconnected);
        Future.delayed(const Duration(seconds: 3), () => connect(context));
      })
      // message:new : on reçoit déjà un JSON `{ id, senderId, conversationId, ... }`
      ..on('message:new', (data) {
        final Map<String, dynamic> json = data as Map<String, dynamic>;
        // on utilise la factory qui ne prend qu'un Map
        final msg = Message.fromJson(json);
        onNewMessage?.call(msg);
      })
      ..on('conversation:user_added', (data) {
        final Map<String, dynamic> json = data as Map<String, dynamic>;
        onUserAdded?.call(
          json['conversationId'] as String,
          json['userId'] as String,
        );
      })
      ..on('notification:new', (_) => onNotificationNew?.call())
      ..on('conversation:joined', (_) => onConversationJoined?.call())
      ..on('group:joined', (_) => onGroupJoined?.call())
      ..on('group:user_added', (data) {
        final Map<String, dynamic> json = data as Map<String, dynamic>;
        _log(
          'Nouvel utilisateur ajouté au groupe '
          '${json['groupId']} : ${json['userId']}',
          level: 'info',
        );
      })
      ..onError((err) => _handleError('Erreur WebSocket: $err'))
      ..on('connect_error', (err) => _handleError('Erreur de connexion: $err'));
  }

  void subscribeConversation(String conversationId) {
    if (_status != SocketStatus.connected || _socket == null) return;
    _log('Demande d’abonnement à la conversation : $conversationId', level: 'info');
    _socket!.emitWithAck(
      'conversation:subscribe',
      conversationId,
      ack: (resp) {
        final ok = resp is Map && resp['success'] == true;
        _log(ok
            ? 'Abonnement réussi à $conversationId'
            : 'Échec abonnement à $conversationId (ack: $resp)',
          level: ok ? 'info' : 'warn'
        );
      },
    );
  }

  void unsubscribeConversation(String conversationId) {
    if (_status != SocketStatus.connected || _socket == null) return;
    _log('Désabonnement de la conversation : $conversationId', level: 'info');
    _socket!.emit('conversation:unsubscribe', conversationId);
  }

  void disconnect() {
    _disposeSocket();
    _updateStatus(SocketStatus.disconnected);
  }

  void _disposeSocket() {
    _socket?.clearListeners();
    _socket?.disconnect();
    _socket = null;
  }

  void _updateStatus(SocketStatus newStatus) {
    _status = newStatus;
    _statusController.add(_status);
  }

  void _handleError(String message) {
    _log(message, level: 'error');
    _updateStatus(SocketStatus.error);
  }

  void _log(String message, {String level = 'info'}) {
    print('[WebSocketService][$level] $message');
  }
}
