import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/models/group_info.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/services/api_service.dart';
import 'package:flutter_message_app/core/services/websocket_service.dart';
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';

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

  final AuthProvider _authProvider;
  
  GroupProvider(AuthProvider authProvider)
      : _authProvider = authProvider,
        _apiService = ApiService(authProvider),
        _webSocketService = WebSocketService.instance {
    debugPrint('🏗️ [GroupProvider] Setting up WebSocket callbacks');
    _webSocketService.onGroupJoined = _onWebSocketGroupJoined;
    _webSocketService.onGroupCreated = _onWebSocketGroupCreated;
    _webSocketService.onGroupMemberJoined = _onWebSocketGroupMemberJoined;
    debugPrint('🏗️ [GroupProvider] onGroupJoined callback set: ${_webSocketService.onGroupJoined != null}');
    debugPrint('🏗️ [GroupProvider] onGroupMemberJoined callback set: ${_webSocketService.onGroupMemberJoined != null}');
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
      
      // Générer et publier les clés du créateur pour permettre l'envoi de messages
      final deviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      
      // S'assurer que les clés device sont générées
      await KeyManagerFinal.instance.ensureKeysFor(groupId, deviceId);
      
      final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(groupId, deviceId);
      final sigPub = pubKeys['pk_sig']!;
      final kemPub = pubKeys['pk_kem']!;
      
      await _apiService.publishGroupDeviceKey(
        groupId: groupId,
        deviceId: deviceId,
        pkSigB64: sigPub,
        pkKemB64: kemPub,
      );
      
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
      // Ne pas rethrow pour éviter les erreurs de widget unmounted
    }
  }

  /// Envoie une demande de jointure avec génération des clés device.
  Future<void> sendJoinRequest(
    String groupId,
    String publicKeyGroup, {
    required String groupSigningPubKeyB64,
    required String groupKEMPubKeyB64,
  }) async {
    try {
      // 🚀 NOUVEAU: Générer les clés device lors de la demande
      final deviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      await KeyManagerFinal.instance.ensureKeysFor(groupId, deviceId);
      
      final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(groupId, deviceId);
      final deviceSigPub = pubKeys['pk_sig']!;
      final deviceKemPub = pubKeys['pk_kem']!;
      
      await _apiService.sendJoinRequestWithDeviceKeys(
        groupId: groupId,
        groupSigningPubKeyB64: groupSigningPubKeyB64,
        groupKEMPubKeyB64: groupKEMPubKeyB64,
        deviceId: deviceId,
        deviceSigPubKeyB64: deviceSigPub,
        deviceKemPubKeyB64: deviceKemPub,
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
      final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(groupId, deviceId);
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

  /// Liste mes devices pour le groupe (actifs et révoqués)
  Future<void> fetchMyDevices(String groupId, String myUserId) async {
    try {
      // CORRECTION: Utiliser le nouvel endpoint dédié qui retourne tous les devices de l'utilisateur
      // Cela évite de récupérer tous les devices du groupe et de filtrer côté client
      _myDevices = await _apiService.fetchMyGroupDeviceKeys(groupId);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ GroupProvider.fetchMyDevices error: $e');
      // Fallback: utiliser l'ancienne méthode si le nouvel endpoint n'existe pas encore
      try {
        final entries = await _apiService.fetchGroupDeviceKeys(groupId);
        _myDevices = entries
            .where((e) => e['userId'] == myUserId)
            .toList();
        notifyListeners();
      } catch (fallbackError) {
        debugPrint('❌ GroupProvider.fetchMyDevices fallback error: $fallbackError');
      }
    }
  }

  /// Révoquer un device pour le groupe
  Future<void> revokeMyDevice(String groupId, String deviceId) async {
    try {
      await _apiService.revokeGroupDevice(groupId: groupId, deviceId: deviceId);
      // CORRECTION: Rafraîchir depuis le serveur au lieu de supprimer localement
      // Cela garantit que la liste est à jour et reflète le statut 'revoked' si nécessaire
      final myUserId = _authProvider.userId;
      if (myUserId != null) {
        await fetchMyDevices(groupId, myUserId);
      } else {
        // Fallback: supprimer localement si userId n'est pas disponible
        _myDevices.removeWhere((d) => d['deviceId'] == deviceId);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('❌ GroupProvider.revokeMyDevice error: $e');
      rethrow;
    }
  }

  /// Publish device keys for a group (public interface)
  Future<void> publishDeviceKeys(String groupId, String deviceId, String pkSigB64, String pkKemB64) async {
    try {
      await _apiService.publishGroupDeviceKey(
        groupId: groupId,
        deviceId: deviceId,
        pkSigB64: pkSigB64,
        pkKemB64: pkKemB64,
      );
    } catch (e) {
      debugPrint('❌ GroupProvider.publishDeviceKeys error: $e');
      rethrow;
    }
  }
    
  void _onWebSocketGroupCreated(String groupId, String creatorId) {
    debugPrint('🏗️ [GroupProvider] Group created event received: $groupId by $creatorId');
    // CORRECTION: Rafraîchir immédiatement la liste des groupes
    fetchUserGroups();
  }
  
  void _onWebSocketGroupMemberJoined(String groupId, String userId, String approverId) {
    debugPrint('👥 [GroupProvider] Group member joined event received: $userId in $groupId by $approverId');
    debugPrint('👥 [GroupProvider] Refreshing groups list...');
    // CORRECTION: Rafraîchir immédiatement la liste des groupes
    fetchUserGroups();
    debugPrint('👥 [GroupProvider] Groups list refreshed');
  }
  
  void _onWebSocketGroupJoined(String groupId, String userId, String approverId) {
    debugPrint('👥 [GroupProvider] Group joined event received: $userId in $groupId by $approverId');
    debugPrint('👥 [GroupProvider] Refreshing groups list for joined user...');
    // CORRECTION: Rafraîchir immédiatement la liste des groupes pour l'utilisateur qui a rejoint
    fetchUserGroups();
    debugPrint('👥 [GroupProvider] Groups list refreshed for joined user');
  }
}
