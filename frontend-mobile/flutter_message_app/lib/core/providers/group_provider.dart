import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/models/group_info.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/services/api_service.dart';
import 'package:flutter_message_app/core/services/websocket_service.dart';
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'package:flutter_message_app/core/crypto/key_manager_v2.dart';

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
  List<Map<String, dynamic>> _myDevices = <Map<String, dynamic>>[];

  GroupProvider(AuthProvider authProvider)
      : _apiService = ApiService(authProvider),
        _webSocketService = WebSocketService.instance {
          _webSocketService.onGroupJoined = _onWebSocketGroupJoined;
 }

  Map<String, dynamic>? get groupDetail => _groupDetail;
  List<Map<String, dynamic>> get joinRequests => _joinRequests;
  List<Map<String, dynamic>> get members => _members;
  List<Map<String, dynamic>> get myDevices => _myDevices;

  /// Crée un nouveau groupe et renvoie son ID.
  Future<String> createGroup(String name, String publicKeyGroup, {
    required String groupSigningPubKeyB64,
    required String groupKEMPubKeyB64,
  }) async {
    try {
      final String groupId = await _apiService.createGroup(
        name: name,
        groupSigningPubKeyB64: groupSigningPubKeyB64,
        groupKEMPubKeyB64: groupKEMPubKeyB64,
      );
      return groupId;
    } catch (error) {
      debugPrint('❌ GroupProvider.createGroup error: $error');
      rethrow;
    }
  }

  /// Crée un nouveau groupe avec les membres spécifiés.
  Future<String> createGroupWithMembers({
    required String groupName,
    required List<String> memberEmails,
    required String groupSigningPubKeyB64,
    required String groupKEMPubKeyB64,
  }) async {
    try {
      final String groupId = await _apiService.createGroup(
        name: groupName,
        groupSigningPubKeyB64: groupSigningPubKeyB64,
        groupKEMPubKeyB64: groupKEMPubKeyB64,
      );
      
      // Publier les clés du créateur pour permettre l'envoi de messages
      final deviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      final pubKeys = await KeyManagerV2.instance.publicKeysBase64(groupId, deviceId);
      final sigPub = pubKeys['pk_sig']!;
      final kemPub = pubKeys['pk_kem']!;
      
      await _apiService.publishGroupDeviceKey(
        groupId: groupId,
        deviceId: deviceId,
        pkSigB64: sigPub,
        pkKemB64: kemPub,
      );
      
      debugPrint('✅ Clés du créateur publiées pour le groupe $groupId');
      
      // Refresh groups list
      await fetchUserGroups();
      
      return groupId;
    } catch (error) {
      debugPrint('❌ GroupProvider.createGroupWithMembers error: $error');
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
    String publicKeyGroup, {
    required String groupSigningPubKeyB64,
    required String groupKEMPubKeyB64,
  }) async {
    try {
      await _apiService.sendJoinRequest(
        groupId: groupId,
        groupSigningPubKeyB64: groupSigningPubKeyB64,
        groupKEMPubKeyB64: groupKEMPubKeyB64,
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
      // Publier les clés du device courant après acceptation
      final deviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      final pubKeys = await KeyManagerV2.instance.publicKeysBase64(groupId, deviceId);
      final sigPub = pubKeys['pk_sig']!;
      final kemPub = pubKeys['pk_kem']!;
      await _apiService.publishGroupDeviceKey(
        groupId: groupId,
        deviceId: deviceId,
        pkSigB64: sigPub,
        pkKemB64: kemPub,
      );
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

  /// Liste mes devices actifs pour le groupe
  Future<void> fetchMyDevices(String groupId, String myUserId) async {
    try {
      final entries = await _apiService.fetchGroupDeviceKeys(groupId);
      _myDevices = entries
          .where((e) => e['userId'] == myUserId)
          .toList();
      notifyListeners();
    } catch (e) {
      debugPrint('❌ GroupProvider.fetchMyDevices error: $e');
    }
  }

  /// Révoquer un device pour le groupe
  Future<void> revokeMyDevice(String groupId, String deviceId) async {
    try {
      await _apiService.revokeGroupDevice(groupId: groupId, deviceId: deviceId);
      _myDevices.removeWhere((d) => d['deviceId'] == deviceId);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ GroupProvider.revokeMyDevice error: $e');
      rethrow;
    }
  }
    
  void _onWebSocketGroupJoined() {
    fetchUserGroups();
  }
}
