import 'package:flutter/foundation.dart';

/// Service pour gérer les badges de notification dans l'UI
/// Les badges indiquent qu'il y a de nouveaux événements sans révéler d'informations sensibles
class NotificationBadgeService extends ChangeNotifier {
  static final NotificationBadgeService _instance = NotificationBadgeService._internal();
  factory NotificationBadgeService() => _instance;
  NotificationBadgeService._internal();

  // Map conversationId -> groupId pour associer les conversations aux groupes
  final Map<String, String> _conversationToGroup = {};
  
  // Set des conversations avec de nouveaux messages (pour afficher des badges sur chaque conversation)
  final Set<String> _conversationsWithNewMessages = {};
  Set<String> get conversationsWithNewMessages => Set.unmodifiable(_conversationsWithNewMessages);

  // Set des nouvelles conversations (créées récemment) par groupe
  final Map<String, Set<String>> _newConversationsByGroup = {}; // groupId -> Set<conversationId>

  // Set des groupes avec de nouveaux messages (pour afficher des badges sur les groupes dans HomeScreen)
  final Set<String> _groupsWithNewMessages = {};
  Set<String> get groupsWithNewMessages => Set.unmodifiable(_groupsWithNewMessages);

  // Compteur d'updates pour un groupe spécifique (nouvelles conversations + nouveaux messages)
  int getUpdatesCountForGroup(String groupId) {
    final newMessagesCount = _conversationsWithNewMessages.where((convId) {
      return _conversationToGroup[convId] == groupId;
    }).length;
    final newConversationsCount = _newConversationsByGroup[groupId]?.length ?? 0;
    return newMessagesCount + newConversationsCount;
  }

  // Compteur de nouveaux messages pour un groupe spécifique (seulement les messages, pas les nouvelles conversations)
  int getNewMessagesCountForGroup(String groupId) {
    return _conversationsWithNewMessages.where((convId) {
      return _conversationToGroup[convId] == groupId;
    }).length;
  }
  
  // Compte le nombre de groupes AUTRES que le groupe actuel qui ont des updates
  int getOtherGroupsUpdatesCount(String currentGroupId) {
    // Compter les groupes avec de nouveaux messages (autres que le groupe actuel)
    final otherGroupsWithMessages = _groupsWithNewMessages.where((groupId) => groupId != currentGroupId).toSet();
    // Compter les groupes avec de nouvelles conversations (autres que le groupe actuel)
    final otherGroupsWithNewConvs = _newConversationsByGroup.keys.where((groupId) => groupId != currentGroupId).toSet();
    // Union des deux sets pour avoir le nombre total de groupes autres avec des updates
    return otherGroupsWithMessages.union(otherGroupsWithNewConvs).length;
  }

  // Compteur total de nouveaux messages (tous groupes confondus)
  int get newMessagesCount => _conversationsWithNewMessages.length;

  // Indicateur de nouveaux groupes (pour l'icône de cercle)
  bool _hasNewGroups = false;
  bool get hasNewGroups => _hasNewGroups;
  
  // Vérifie si un groupe a de nouveaux messages
  bool hasNewMessagesInGroup(String groupId) {
    return _groupsWithNewMessages.contains(groupId);
  }

  /// Incrémente le compteur de nouveaux messages (déprécié, utiliser markConversationAsNew)
  @Deprecated('Utiliser markConversationAsNew à la place')
  void incrementNewMessages() {
    // Ne plus utiliser cette méthode, le compteur est maintenant basé sur le nombre de conversations
    notifyListeners();
  }

  /// Réinitialise le compteur de nouveaux messages (quand l'utilisateur ouvre l'onglet Messages)
  void clearNewMessages() {
    if (_conversationsWithNewMessages.isNotEmpty) {
      _conversationsWithNewMessages.clear();
      debugPrint('🔔 [BadgeService] Tous les badges de messages réinitialisés');
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
  /// groupId est optionnel mais recommandé pour le filtrage par groupe
  void markConversationAsNew(String conversationId, {String? groupId}) {
    if (_conversationsWithNewMessages.add(conversationId)) {
      if (groupId != null) {
        _conversationToGroup[conversationId] = groupId;
        _groupsWithNewMessages.add(groupId);
      }
      notifyListeners();
    }
  }
  
  /// Marque une nouvelle conversation créée dans un groupe
  void markNewConversation(String conversationId, String groupId) {
    _newConversationsByGroup.putIfAbsent(groupId, () => <String>{});
    if (_newConversationsByGroup[groupId]!.add(conversationId)) {
      _groupsWithNewMessages.add(groupId);
      notifyListeners();
    }
  }

  /// Marque une conversation comme lue (plus de nouveaux messages)
  /// Le compteur est automatiquement mis à jour car il est basé sur le nombre de conversations
  void markConversationAsRead(String conversationId) {
    bool changed = false;
    
    // Retirer des conversations avec nouveaux messages
    if (_conversationsWithNewMessages.remove(conversationId)) {
      changed = true;
    }
    
    final groupId = _conversationToGroup.remove(conversationId);
    
    // CORRECTION: Retirer aussi des nouvelles conversations si c'était une nouvelle conversation
    if (groupId != null) {
      final newConvsInGroup = _newConversationsByGroup[groupId];
      if (newConvsInGroup != null && newConvsInGroup.remove(conversationId)) {
        changed = true;
        // Si plus de nouvelles conversations dans ce groupe, supprimer l'entrée
        if (newConvsInGroup.isEmpty) {
          _newConversationsByGroup.remove(groupId);
        }
      }
      
      // Vérifier si le groupe a encore des conversations avec de nouveaux messages ou nouvelles conversations
      final hasOtherNewMessages = _conversationsWithNewMessages.any((convId) {
        return _conversationToGroup[convId] == groupId;
      });
      final hasOtherNewConversations = (_newConversationsByGroup[groupId]?.isNotEmpty ?? false);
      
      if (!hasOtherNewMessages && !hasOtherNewConversations) {
        _groupsWithNewMessages.remove(groupId);
      }
    }
    
    if (changed) {
      debugPrint('🔔 [BadgeService] Conversation $conversationId marquée comme lue, compteur: ${_conversationsWithNewMessages.length}');
      notifyListeners();
    }
  }

  /// Réinitialise tous les badges
  void clearAll() {
    _hasNewGroups = false;
    _conversationsWithNewMessages.clear();
    _conversationToGroup.clear();
    _groupsWithNewMessages.clear();
    _newConversationsByGroup.clear();
    notifyListeners();
  }
  
  /// Marque tous les messages d'un groupe comme lus (quand on ouvre le groupe)
  void markGroupAsRead(String groupId) {
    final conversationsToRemove = _conversationsWithNewMessages.where((convId) {
      return _conversationToGroup[convId] == groupId;
    }).toList();
    
    for (final convId in conversationsToRemove) {
      _conversationsWithNewMessages.remove(convId);
      _conversationToGroup.remove(convId);
    }
    
    // Nettoyer aussi les nouvelles conversations du groupe
    _newConversationsByGroup.remove(groupId);
    
    // Vérifier si le groupe a encore des updates
    final hasOtherUpdates = _conversationsWithNewMessages.any((convId) {
      return _conversationToGroup[convId] == groupId;
    });
    if (!hasOtherUpdates && !_newConversationsByGroup.containsKey(groupId)) {
      _groupsWithNewMessages.remove(groupId);
    }
    
    notifyListeners();
  }
}

