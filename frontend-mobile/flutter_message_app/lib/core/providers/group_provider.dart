import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_message_app/core/models/group_info.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/providers/conversation_provider.dart';
import 'package:flutter_message_app/core/services/api_service.dart';
import 'package:flutter_message_app/core/services/websocket_service.dart';
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'package:flutter_message_app/core/services/notification_badge_service.dart';
import 'package:flutter_message_app/core/services/persistent_message_key_cache.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';

/// Gère les opérations liées aux groupes et aux demandes de jointure.
class GroupProvider extends ChangeNotifier {
  final ApiService _apiService;
  final WebSocketService _webSocketService;

  /// Liste typée des groupes.
  List<GroupInfo> _groups = <GroupInfo>[];

  // ✅ OPTIMISATION: Cache pour éviter les appels multiples
  bool _groupsLoaded = false;
  DateTime? _lastGroupsLoad;
  static const Duration _groupsCacheDuration = Duration(seconds: 10);

  /// Expose la liste des groupes.
  List<GroupInfo> get groups => _groups;

  /// Détail du groupe actuellement affiché.
  Map<String, dynamic>? _groupDetail;

  /// Liste des demandes de jointure du groupe.
  List<Map<String, dynamic>> _joinRequests = <Map<String, dynamic>>[];

  /// Liste des membres du groupe.
  List<Map<String, dynamic>> _members = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _myDevices = <Map<String, dynamic>>[];

  /// Liste des notifications in-app en attente d'affichage
  final List<Map<String, dynamic>> _pendingInAppNotifications = [];

  final AuthProvider _authProvider;

  GroupProvider(AuthProvider authProvider)
    : _authProvider = authProvider,
      _apiService = ApiService(authProvider),
      _webSocketService = WebSocketService.instance {
    debugPrint('🏗️ [GroupProvider] Setting up WebSocket callbacks');
    _webSocketService.onGroupJoined = _onWebSocketGroupJoined;
    _webSocketService.onGroupCreated = _onWebSocketGroupCreated;
    _webSocketService.onGroupMemberJoined = _onWebSocketGroupMemberJoined;
    debugPrint(
      '🏗️ [GroupProvider] onGroupJoined callback set: ${_webSocketService.onGroupJoined != null}',
    );
    debugPrint(
      '🏗️ [GroupProvider] onGroupMemberJoined callback set: ${_webSocketService.onGroupMemberJoined != null}',
    );
  }

  Map<String, dynamic>? get groupDetail => _groupDetail;
  List<Map<String, dynamic>> get joinRequests => _joinRequests;
  List<Map<String, dynamic>> get members => _members;
  List<Map<String, dynamic>> get myDevices => _myDevices;

  /// Crée un nouveau groupe et renvoie son ID.
  Future<String> createGroup(
    String name,
    String publicKeyGroup, {
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
      final deviceId =
          await SessionDeviceService.instance.getOrCreateDeviceId();

      // S'assurer que les clés device sont générées
      await KeyManagerFinal.instance.ensureKeysFor(groupId, deviceId);

      final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(
        groupId,
        deviceId,
      );
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
  Future<void> fetchUserGroups({bool forceRefresh = false}) async {
    try {
      // ✅ OPTIMISATION: Vérifier si déjà chargé récemment
      final now = DateTime.now();
      if (!forceRefresh &&
          _groupsLoaded &&
          _lastGroupsLoad != null &&
          now.difference(_lastGroupsLoad!) < _groupsCacheDuration) {
        debugPrint('📡 [GroupProvider] Groupes déjà chargés récemment, skip');
        return;
      }

      _groups = await _apiService.fetchUserGroups();

      // ✅ OPTIMISATION: Mettre à jour les flags
      _groupsLoaded = true;
      _lastGroupsLoad = now;

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
      final deviceId =
          await SessionDeviceService.instance.getOrCreateDeviceId();
      await KeyManagerFinal.instance.ensureKeysFor(groupId, deviceId);

      final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(
        groupId,
        deviceId,
      );
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
      final deviceId =
          await SessionDeviceService.instance.getOrCreateDeviceId();
      final pubKeys = await KeyManagerFinal.instance.publicKeysBase64(
        groupId,
        deviceId,
      );
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
        _myDevices = entries.where((e) => e['userId'] == myUserId).toList();
        notifyListeners();
      } catch (fallbackError) {
        debugPrint(
          '❌ GroupProvider.fetchMyDevices fallback error: $fallbackError',
        );
      }
    }
  }

  /// Révoquer un device pour le groupe
  Future<void> revokeMyDevice(
    String groupId,
    String deviceId, {
    BuildContext? context,
  }) async {
    try {
      await _apiService.revokeGroupDevice(groupId: groupId, deviceId: deviceId);

      // Rafraîchir depuis le serveur
      final myUserId = _authProvider.userId;
      if (myUserId != null) {
        await fetchMyDevices(groupId, myUserId);
      } else {
        // Fallback: supprimer localement si userId n'est pas disponible
        _myDevices.removeWhere((d) => d['deviceId'] == deviceId);
        notifyListeners();
      }

      // Invalider les caches
      // 1. Cache group keys (via ConversationProvider si disponible)
      if (context != null) {
        try {
          final conversationProvider = context.read<ConversationProvider>();
          await conversationProvider.keyDirectory.invalidateDeviceKeys(
            groupId,
            deviceId,
          );
        } catch (e) {
          debugPrint('⚠️ Erreur invalidation group keys: $e');
        }
      }

      // 2. Cache message keys
      await PersistentMessageKeyCache.instance.invalidateKeysForDevice(
        groupId,
        deviceId,
      );
    } catch (e) {
      debugPrint('❌ GroupProvider.revokeMyDevice error: $e');
      rethrow;
    }
  }

  /// Publish device keys for a group (public interface)
  Future<void> publishDeviceKeys(
    String groupId,
    String deviceId,
    String pkSigB64,
    String pkKemB64,
  ) async {
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

  void _onWebSocketGroupCreated(String? groupId, String? creatorId) {
    // SÉCURITÉ: Les paramètres peuvent être null si c'est un ping minimal
    if (groupId == null || creatorId == null) {
      debugPrint(
        '🏗️ [GroupProvider] Ping reçu pour nouveau groupe (pas de données sensibles)',
      );
      // Rafraîchir les groupes pour récupérer le nouveau
      fetchUserGroups();
      // Marquer qu'il y a de nouveaux groupes
      NotificationBadgeService().setHasNewGroups(true);
      return;
    }

    debugPrint(
      '🏗️ [GroupProvider] Group created event received: $groupId by $creatorId',
    );
    // CORRECTION: Rafraîchir immédiatement la liste des groupes
    fetchUserGroups()
        .then((_) {
          // Après avoir récupéré les groupes, ajouter la notification
          final myUserId = _authProvider.userId;

          // Ne pas notifier si c'est nous qui avons créé le groupe (on est déjà dessus)
          if (myUserId != null && creatorId == myUserId) {
            debugPrint(
              '🏗️ [GroupProvider] Groupe créé par nous-même, pas de notification',
            );
            return;
          }

          // Marquer qu'il y a de nouveaux groupes
          NotificationBadgeService().setHasNewGroups(true);

          // Trouver le nom du groupe depuis la liste mise à jour
          String? groupName;
          try {
            final group = _groups.firstWhere(
              (g) => g.groupId == groupId,
              orElse: () => throw Exception('Group not found'),
            );
            groupName = group.name;
          } catch (e) {
            // Le groupe n'est pas encore dans la liste, on utilisera juste l'ID
            debugPrint(
              '⚠️ [GroupProvider] Groupe $groupId pas encore dans la liste après fetch',
            );
          }

          _pendingInAppNotifications.add({
            'type': 'new_group',
            'groupId': groupId,
            'groupName': groupName,
          });

          debugPrint(
            '🔔 [GroupProvider] Notification in-app ajoutée pour nouveau groupe: $groupId',
          );
          // Notifier les listeners pour que l'UI puisse afficher la notification
          notifyListeners();
        })
        .catchError((e) {
          debugPrint('❌ [GroupProvider] Erreur lors du fetch des groupes: $e');
        });
  }

  /// Obtient et supprime les notifications in-app en attente
  List<Map<String, dynamic>> getPendingInAppNotifications() {
    final notifications = List<Map<String, dynamic>>.from(
      _pendingInAppNotifications,
    );
    _pendingInAppNotifications.clear();
    return notifications;
  }

  void _onWebSocketGroupMemberJoined(
    String? groupId,
    String? userId,
    String? approverId,
  ) {
    // CORRECTION: Le ping contient maintenant groupId pour identifier précisément le groupe
    if (groupId == null) {
      debugPrint(
        '⚠️ [GroupProvider] Ping reçu pour membre rejoint sans groupId',
      );
      // Fallback: rafraîchir tous les groupes
      fetchUserGroups();
      return;
    }

    // userId et approverId peuvent être null dans le ping, mais groupId est maintenant toujours présent
    if (userId == null || approverId == null) {
      debugPrint(
        '👥 [GroupProvider] Ping reçu pour membre rejoint: groupe $groupId (sans userId/approverId)',
      );
    } else {
      debugPrint(
        '👥 [GroupProvider] Group member joined event received: $userId in $groupId by $approverId',
      );
    }

    debugPrint(
      '👥 [GroupProvider] Group member joined event received: $userId in $groupId by $approverId',
    );
    debugPrint('👥 [GroupProvider] Refreshing groups list...');
    // CORRECTION: Rafraîchir immédiatement la liste des groupes
    fetchUserGroups();
    debugPrint('👥 [GroupProvider] Groups list refreshed');
  }

  void _onWebSocketGroupJoined(
    String? groupId,
    String? userId,
    String? approverId,
  ) {
    // CORRECTION: Le ping contient maintenant groupId pour identifier précisément le groupe
    if (groupId == null) {
      debugPrint(
        '⚠️ [GroupProvider] Ping reçu pour groupe rejoint sans groupId',
      );
      // Fallback: rafraîchir tous les groupes
      fetchUserGroups();
      NotificationBadgeService().setHasNewGroups(true);
      return;
    }

    // userId et approverId peuvent être null dans le ping, mais groupId est maintenant toujours présent
    if (userId == null || approverId == null) {
      debugPrint(
        '👥 [GroupProvider] Ping reçu pour groupe rejoint: $groupId (sans userId/approverId)',
      );
    } else {
      debugPrint(
        '👥 [GroupProvider] Group joined event received: $userId in $groupId by $approverId',
      );
    }

    debugPrint(
      '👥 [GroupProvider] Group joined event received: $userId in $groupId by $approverId',
    );
    debugPrint('👥 [GroupProvider] Refreshing groups list for joined user...');
    // CORRECTION: Rafraîchir immédiatement la liste des groupes pour l'utilisateur qui a rejoint
    fetchUserGroups();
    // Marquer qu'il y a de nouveaux groupes
    NotificationBadgeService().setHasNewGroups(true);
    debugPrint('👥 [GroupProvider] Groups list refreshed for joined user');
  }
}
