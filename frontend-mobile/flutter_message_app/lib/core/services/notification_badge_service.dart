import 'package:flutter/foundation.dart';

/// Service pour gérer les badges de notification dans l'UI
/// Les badges indiquent qu'il y a de nouveaux événements sans révéler d'informations sensibles
class NotificationBadgeService extends ChangeNotifier {
  static final NotificationBadgeService _instance = NotificationBadgeService._internal();
  factory NotificationBadgeService() => _instance;
  NotificationBadgeService._internal();

  // Compteur de nouveaux messages (pour l'onglet Messages)
  int _newMessagesCount = 0;
  int get newMessagesCount => _newMessagesCount;

  // Indicateur de nouveaux groupes (pour l'icône de cercle)
  bool _hasNewGroups = false;
  bool get hasNewGroups => _hasNewGroups;

  // Set des conversations avec de nouveaux messages (pour afficher des badges sur chaque conversation)
  final Set<String> _conversationsWithNewMessages = {};
  Set<String> get conversationsWithNewMessages => Set.unmodifiable(_conversationsWithNewMessages);

  /// Incrémente le compteur de nouveaux messages
  void incrementNewMessages() {
    _newMessagesCount++;
    notifyListeners();
  }

  /// Réinitialise le compteur de nouveaux messages (quand l'utilisateur ouvre l'onglet Messages)
  void clearNewMessages() {
    if (_newMessagesCount > 0) {
      _newMessagesCount = 0;
      notifyListeners();
    }
  }

  /// Marque qu'il y a de nouveaux groupes
  void setHasNewGroups(bool value) {
    if (_hasNewGroups != value) {
      _hasNewGroups = value;
      notifyListeners();
    }
  }

  /// Marque une conversation comme ayant de nouveaux messages
  void markConversationAsNew(String conversationId) {
    if (_conversationsWithNewMessages.add(conversationId)) {
      notifyListeners();
    }
  }

  /// Marque une conversation comme lue (plus de nouveaux messages)
  void markConversationAsRead(String conversationId) {
    if (_conversationsWithNewMessages.remove(conversationId)) {
      notifyListeners();
    }
  }

  /// Réinitialise tous les badges
  void clearAll() {
    _newMessagesCount = 0;
    _hasNewGroups = false;
    _conversationsWithNewMessages.clear();
    notifyListeners();
  }
}

