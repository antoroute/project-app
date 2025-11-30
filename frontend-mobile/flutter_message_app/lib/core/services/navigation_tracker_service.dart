import 'package:flutter/material.dart';

/// Service pour suivre l'écran actuel et la conversation ouverte
/// Permet de savoir si l'utilisateur est dans une conversation spécifique
class NavigationTrackerService {
  static final NavigationTrackerService _instance = NavigationTrackerService._internal();
  factory NavigationTrackerService() => _instance;
  NavigationTrackerService._internal();

  /// ID de la conversation actuellement ouverte (null si aucune)
  String? _currentConversationId;
  
  /// Nom de l'écran actuel (pour debug)
  String? _currentScreen;
  
  /// Callbacks pour notifier les changements
  final List<VoidCallback> _listeners = [];

  /// Obtient l'ID de la conversation actuellement ouverte
  String? get currentConversationId => _currentConversationId;
  
  /// Obtient le nom de l'écran actuel
  String? get currentScreen => _currentScreen;

  /// Vérifie si l'utilisateur est actuellement dans une conversation spécifique
  bool isInConversation(String conversationId) {
    return _currentConversationId == conversationId;
  }

  /// Vérifie si l'utilisateur est dans n'importe quelle conversation
  bool isInAnyConversation() {
    return _currentConversationId != null;
  }

  /// Enregistre qu'une conversation est ouverte
  void setConversationOpen(String conversationId) {
    if (_currentConversationId != conversationId) {
      _currentConversationId = conversationId;
      _notifyListeners();
      debugPrint('📍 [NavigationTracker] Conversation ouverte: $conversationId');
    }
  }

  /// Enregistre qu'une conversation est fermée
  void setConversationClosed(String? conversationId) {
    if (_currentConversationId == conversationId || conversationId == null) {
      _currentConversationId = null;
      _notifyListeners();
      debugPrint('📍 [NavigationTracker] Conversation fermée: ${conversationId ?? "toutes"}');
    }
  }

  /// Enregistre l'écran actuel
  void setCurrentScreen(String screenName) {
    if (_currentScreen != screenName) {
      _currentScreen = screenName;
      _notifyListeners();
      debugPrint('📍 [NavigationTracker] Écran actuel: $screenName');
    }
  }

  /// Ajoute un listener pour les changements
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  /// Supprime un listener
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  /// Notifie tous les listeners
  void _notifyListeners() {
    for (final listener in _listeners) {
      try {
        listener();
      } catch (e) {
        debugPrint('⚠️ Erreur dans listener NavigationTracker: $e');
      }
    }
  }

  /// Réinitialise le tracker (utile pour logout)
  void reset() {
    _currentConversationId = null;
    _currentScreen = null;
    _notifyListeners();
    debugPrint('📍 [NavigationTracker] Réinitialisé');
  }
}

