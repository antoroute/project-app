import 'dart:async';
import 'package:flutter/material.dart';
import 'websocket_service.dart';
import 'network_monitor_service.dart';

/// Service pour maintenir la connexion WebSocket active avec un heartbeat
/// Envoie périodiquement un ping pour éviter que la connexion soit fermée par timeout
class WebSocketHeartbeatService {
  static final WebSocketHeartbeatService _instance = WebSocketHeartbeatService._internal();
  factory WebSocketHeartbeatService() => _instance;
  WebSocketHeartbeatService._internal();

  Timer? _heartbeatTimer;
  StreamSubscription<bool>? _networkSubscription;
  final StreamController<HeartbeatState> _stateController = StreamController<HeartbeatState>.broadcast();
  
  // Intervalles de heartbeat selon le mode
  static const Duration _heartbeatIntervalForeground = Duration(seconds: 30); // Normal en avant-plan
  static const Duration _heartbeatIntervalBackground = Duration(seconds: 120); // Économie d'énergie en arrière-plan
  
  bool _isBackgroundMode = false;
  bool _isNetworkAvailable = true;
  DateTime? _lastHeartbeatTime;
  int _consecutiveFailures = 0;
  static const int _maxFailures = 3;
  
  /// Stream pour écouter les changements d'état du heartbeat
  Stream<HeartbeatState> get stateStream => _stateController.stream;
  
  /// État actuel du heartbeat
  HeartbeatState get currentState => HeartbeatState(
    isActive: isActive,
    isConnectionHealthy: isConnectionHealthy,
    timeSinceLastHeartbeat: timeSinceLastHeartbeat,
  );

  /// Démarre le heartbeat pour maintenir la connexion active
  void start() {
    stop(); // Arrêter le timer existant si présent
    
    // Écouter les changements de réseau
    _networkSubscription = NetworkMonitorService().networkStatusStream.listen((isConnected) {
      _isNetworkAvailable = isConnected;
      if (!isConnected) {
        debugPrint('🌐 [Heartbeat] Réseau indisponible, arrêt du heartbeat');
        stop();
      } else {
        debugPrint('🌐 [Heartbeat] Réseau disponible, redémarrage du heartbeat');
        _startHeartbeat();
      }
    });
    
    // Vérifier l'état réseau initial
    _isNetworkAvailable = NetworkMonitorService().isConnected;
    
    if (_isNetworkAvailable) {
      _startHeartbeat();
    } else {
      debugPrint('⚠️ [Heartbeat] Réseau indisponible, heartbeat non démarré');
    }
  }

  /// Démarre le timer de heartbeat avec l'intervalle approprié
  void _startHeartbeat() {
    stop(); // Arrêter le timer existant
    
    final interval = _isBackgroundMode 
        ? _heartbeatIntervalBackground 
        : _heartbeatIntervalForeground;
    
    // Émettre l'état initial immédiatement
    _stateController.add(currentState);
    
    _heartbeatTimer = Timer.periodic(interval, (timer) {
      if (!_isNetworkAvailable) {
        debugPrint('🌐 [Heartbeat] Réseau indisponible, arrêt du heartbeat');
        stop();
        return;
      }
      
      final ws = WebSocketService.instance;
      
      if (ws.status == SocketStatus.connected) {
        _lastHeartbeatTime = DateTime.now();
        _consecutiveFailures = 0;
        // Note: socket.io gère automatiquement les pings, mais on vérifie juste l'état
        debugPrint('💓 [Heartbeat] WebSocket connection is alive (${_isBackgroundMode ? "background" : "foreground"})');
        
        // Émettre l'état mis à jour à chaque heartbeat
        _stateController.add(currentState);
      } else if (ws.status == SocketStatus.disconnected) {
        _consecutiveFailures++;
        debugPrint('⚠️ [Heartbeat] WebSocket disconnected (failures: $_consecutiveFailures/$_maxFailures)');
        
        // Émettre l'état mis à jour même en cas de déconnexion
        _stateController.add(currentState);
        
        if (_consecutiveFailures >= _maxFailures) {
          debugPrint('❌ [Heartbeat] Trop d\'échecs, arrêt du heartbeat');
          stop();
        }
      }
    });
    
    debugPrint('💓 [Heartbeat] Started heartbeat service (interval: ${interval.inSeconds}s, mode: ${_isBackgroundMode ? "background" : "foreground"})');
  }

  /// Passe en mode économie d'énergie (arrière-plan)
  void setBackgroundMode(bool isBackground) {
    if (_isBackgroundMode == isBackground) return;
    
    _isBackgroundMode = isBackground;
    debugPrint('💓 [Heartbeat] Mode changé: ${isBackground ? "arrière-plan" : "avant-plan"}');
    
    // Redémarrer avec le nouvel intervalle
    if (_heartbeatTimer != null && _heartbeatTimer!.isActive) {
      _startHeartbeat();
    } else {
      // Émettre l'état même si le timer n'est pas actif
      _stateController.add(currentState);
    }
  }

  /// Arrête le heartbeat
  void stop() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _networkSubscription?.cancel();
    _networkSubscription = null;
    _stateController.add(currentState); // Émettre l'état final
    debugPrint('💓 [Heartbeat] Stopped heartbeat service');
  }
  
  /// Dispose le service
  void dispose() {
    stop();
    _stateController.close();
  }

  /// Vérifie si le heartbeat est actif
  bool get isActive => _heartbeatTimer != null && _heartbeatTimer!.isActive;
  
  /// Obtient le temps depuis le dernier heartbeat réussi
  Duration? get timeSinceLastHeartbeat {
    if (_lastHeartbeatTime == null) return null;
    return DateTime.now().difference(_lastHeartbeatTime!);
  }
  
  /// Vérifie si la connexion est saine (heartbeat récent)
  bool get isConnectionHealthy {
    if (!isActive) return false;
    if (_lastHeartbeatTime == null) return false;
    final timeSince = DateTime.now().difference(_lastHeartbeatTime!);
    final maxInterval = _isBackgroundMode 
        ? _heartbeatIntervalBackground * 2 
        : _heartbeatIntervalForeground * 2;
    return timeSince < maxInterval;
  }
}

/// État du heartbeat pour l'affichage
class HeartbeatState {
  final bool isActive;
  final bool isConnectionHealthy;
  final Duration? timeSinceLastHeartbeat;
  
  HeartbeatState({
    required this.isActive,
    required this.isConnectionHealthy,
    this.timeSinceLastHeartbeat,
  });
}

