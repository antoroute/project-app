import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/models/group_info.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/services/api_service.dart';
import 'package:flutter_message_app/core/services/websocket_service.dart';

/// Gère les opérations liées aux groupes et aux demandes de jointure.
class GroupProvider extends ChangeNotifier {
  final ApiService _apiService;
  final WebSocketService _webSocketService;

  /// Liste typée des groupes.
  List<GroupInfo> _groups = <GroupInfo>[];

  /// Expose la liste des groupes.
  List<GroupInfo> get groups => _groups;

  /// Détail du groupe actuellement affiché.
  Map<String, dynamic>? _groupDetail;

  /// Liste des demandes de jointure du groupe.
  List<Map<String, dynamic>> _joinRequests = <Map<String, dynamic>>[];

  /// Liste des membres du groupe.
  List<Map<String, dynamic>> _members = <Map<String, dynamic>>[];

  GroupProvider(AuthProvider authProvider)
      : _apiService = ApiService(authProvider),
        _webSocketService = WebSocketService.instance {
          _webSocketService.onGroupJoined = _onWebSocketGroupJoined;
 }

  Map<String, dynamic>? get groupDetail => _groupDetail;
  List<Map<String, dynamic>> get joinRequests => _joinRequests;
  List<Map<String, dynamic>> get members => _members;

  /// Crée un nouveau groupe et renvoie son ID.
  Future<String> createGroup(String name, String publicKeyGroup) async {
    try {
      final String groupId = await _apiService.createGroup(
        name: name,
        publicKeyGroup: publicKeyGroup,
      );
      return groupId;
    } catch (error) {
      debugPrint('❌ GroupProvider.createGroup error: $error');
      rethrow;
    }
  }

  /// Récupère la liste des groupes de l'utilisateur.
  Future<void> fetchUserGroups() async {
    try {
      _groups = await _apiService.fetchUserGroups();
      notifyListeners();
    } catch (e) {
      debugPrint('❌ GroupProvider.fetchUserGroups error: $e');
      rethrow;
    }
  }

  /// Récupère les détails d’un groupe.
  Future<void> fetchGroupDetail(String groupId) async {
    try {
      _groupDetail = await _apiService.fetchGroupDetail(groupId);
      notifyListeners();
    } catch (error) {
      debugPrint('❌ GroupProvider.fetchGroupDetail error: $error');
      rethrow;
    }
  }

  /// Envoie une demande de jointure.
  Future<void> sendJoinRequest(
    String groupId,
    String publicKeyGroup,
  ) async {
    try {
      await _apiService.sendJoinRequest(
        groupId: groupId,
        publicKeyGroup: publicKeyGroup,
      );
    } catch (error) {
      debugPrint('❌ GroupProvider.sendJoinRequest error: $error');
      rethrow;
    }
  }

  /// Récupère les demandes de jointure pour un groupe.
  Future<void> fetchJoinRequests(String groupId) async {
    try {
      _joinRequests = await _apiService.fetchJoinRequests(groupId);
      notifyListeners();
    } catch (error) {
      debugPrint('❌ GroupProvider.fetchJoinRequests error: $error');
      rethrow;
    }
  }

  /// Vote oui/non sur une demande de jointure.
  Future<void> voteJoinRequest(
    String groupId,
    String requestId,
    bool vote,
  ) async {
    try {
      final results = await _apiService.voteJoinRequest(
        groupId: groupId,
        requestId: requestId,
        vote: vote,
      );
      // Met à jour localement le comptage
      final idx = _joinRequests.indexWhere((r) => r['id'] == requestId);
      if (idx != -1) {
        _joinRequests[idx]['yesVotes'] = results['yesVotes'];
        _joinRequests[idx]['noVotes']  = results['noVotes'];
        notifyListeners();
      }
    } catch (error) {
      debugPrint('❌ GroupProvider.voteJoinRequest error: $error');
      rethrow;
    }
  }

  /// Accepte ou rejette une demande de jointure.
  Future<void> handleJoinRequest(
    String groupId,
    String requestId,
    String action, // "accept" ou "reject"
  ) async {
    try {
      await _apiService.handleJoinRequest(
        groupId: groupId,
        requestId: requestId,
        action: action,
      );
      // Après traitement, on refait un fetch
      await fetchJoinRequests(groupId);
    } catch (error) {
      debugPrint('❌ GroupProvider.handleJoinRequest error: $error');
      rethrow;
    }
  }

  /// Récupère les membres d’un groupe.
  Future<void> fetchGroupMembers(String groupId) async {
    try {
      _members = await _apiService.fetchGroupMembers(groupId);
      notifyListeners();
    } catch (error) {
      debugPrint('❌ GroupProvider.fetchGroupMembers error: $error');
      rethrow;
    }
  }
    
  void _onWebSocketGroupJoined() {
    fetchUserGroups();
  }
}
