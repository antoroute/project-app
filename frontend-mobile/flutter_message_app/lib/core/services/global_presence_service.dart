import 'package:flutter/foundation.dart';
import 'websocket_service.dart';

/// Service global de présence qui gère les événements de présence
/// au niveau de l'application, indépendamment des écrans spécifiques
class GlobalPresenceService {
  static final GlobalPresenceService _instance = GlobalPresenceService._internal();
  factory GlobalPresenceService() => _instance;
  GlobalPresenceService._internal();

  final Map<String, bool> _userOnline = {};
  final Map<String, int> _userDeviceCount = {};
  final Map<String, Map<String, bool>> _conversationPresence = {};

  /// Callbacks pour notifier les écrans des changements de présence
  final List<VoidCallback> _presenceListeners = [];

  /// Initialise le service de présence global
  void initialize() {
    // Configurer les callbacks WebSocket immédiatement
    _setupWebSocketCallbacks();
  }

  /// Configure les callbacks WebSocket pour la présence
  void _setupWebSocketCallbacks() {
    final webSocketService = WebSocketService.instance;
    
    // Callback pour les événements presence:update
    webSocketService.onPresenceUpdate = (String userId, bool online, int count) {
      final wasOnline = _userOnline[userId] ?? false;
      _userOnline[userId] = online;
      _userDeviceCount[userId] = count;
      
      if (wasOnline != online) {
        _notifyListeners();
      }
    };

    // Callback pour les événements presence:conversation
    webSocketService.onPresenceConversation = (String userId, bool online, int count, String conversationId) {
      _conversationPresence.putIfAbsent(conversationId, () => <String, bool>{});
      
      final wasOnlineInConv = _conversationPresence[conversationId]![userId] ?? false;
      _conversationPresence[conversationId]![userId] = online;
      
      if (wasOnlineInConv != online) {
        _notifyListeners();
      }
    };

    debugPrint('🌍 [GlobalPresence] WebSocket callbacks configured successfully');
  }

  /// Ajoute un listener pour les changements de présence
  void addListener(VoidCallback listener) {
    _presenceListeners.add(listener);
  }

  /// Supprime un listener
  void removeListener(VoidCallback listener) {
    _presenceListeners.remove(listener);
  }

  /// Notifie tous les listeners des changements de présence
  void _notifyListeners() {
    for (final listener in _presenceListeners) {
      try {
        listener();
      } catch (e) {
        debugPrint('🌍 [GlobalPresence] Error notifying listener: $e');
      }
    }
  }

  /// Vérifie si un utilisateur est en ligne
  bool isUserOnline(String userId) {
    return _userOnline[userId] ?? false;
  }

  /// Obtient le nombre de devices connectés pour un utilisateur
  int getUserDeviceCount(String userId) {
    return _userDeviceCount[userId] ?? 0;
  }

  /// Vérifie si un utilisateur est présent dans une conversation
  bool isUserPresentInConversation(String userId, String conversationId) {
    return _conversationPresence[conversationId]?[userId] ?? false;
  }

  /// Obtient tous les utilisateurs en ligne
  Map<String, bool> get allUsersOnline => Map.unmodifiable(_userOnline);

  /// Obtient la présence dans une conversation
  Map<String, bool>? getConversationPresence(String conversationId) {
    return _conversationPresence[conversationId];
  }

  /// Obtient toutes les présences de conversations
  Map<String, Map<String, bool>> get allConversationPresence => Map.unmodifiable(_conversationPresence);

  /// Debug: Affiche l'état actuel de la présence
  void debugPresenceState() {
    debugPrint('🌍 [GlobalPresence] Debug - Current presence state:');
    debugPrint('🌍 [GlobalPresence] _userOnline: $_userOnline');
    debugPrint('🌍 [GlobalPresence] _userDeviceCount: $_userDeviceCount');
    debugPrint('🌍 [GlobalPresence] _conversationPresence: $_conversationPresence');
    debugPrint('🌍 [GlobalPresence] Listeners count: ${_presenceListeners.length}');
  }
}
