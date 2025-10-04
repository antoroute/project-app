import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_message_app/core/services/api_service.dart';

/// Structure d'une entrée (user, device) et clés publiques + empreintes
class GroupDeviceKeyEntry {
  final String userId;
  final String deviceId;
  final String pkSigB64; // Ed25519 public key (32B) base64
  final String pkKemB64; // X25519 public key (32B) base64
  final int keyVersion;
  final String status;

  // Pinning (empreintes SHA-256 sur les pubs)
  final String fingerprintSig; // hex
  final String fingerprintKem; // hex

  GroupDeviceKeyEntry({
    required this.userId,
    required this.deviceId,
    required this.pkSigB64,
    required this.pkKemB64,
    required this.keyVersion,
    required this.status,
    required this.fingerprintSig,
    required this.fingerprintKem,
  });

  static String _sha256HexFromBase64(String b64) {
    final bytes = base64.decode(b64);
    final digest = sha256.convert(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  factory GroupDeviceKeyEntry.fromJson(Map<String, dynamic> json) {
    final pkSig = json['pk_sig'] as String;
    final pkKem = json['pk_kem'] as String;
    return GroupDeviceKeyEntry(
      userId: json['userId'] as String,
      deviceId: json['deviceId'] as String,
      pkSigB64: pkSig,
      pkKemB64: pkKem,
      keyVersion: (json['key_version'] as num).toInt(),
      status: json['status'] as String? ?? 'active',
      fingerprintSig: _sha256HexFromBase64(pkSig),
      fingerprintKem: _sha256HexFromBase64(pkKem),
    );
  }
}

/// Service d'annuaire des clés par groupe avec cache + pinning
class KeyDirectoryService {
  KeyDirectoryService(this._api);

  final ApiService _api;

  // Cache en mémoire: groupId -> entries
  final Map<String, List<GroupDeviceKeyEntry>> _cache = <String, List<GroupDeviceKeyEntry>>{};

  /// Récupère et met en cache la liste (user,device,keys) d'un groupe
  Future<List<GroupDeviceKeyEntry>> fetchGroupDevices(String groupId) async {
    final raw = await _api.fetchGroupDeviceKeys(groupId);
    debugPrint('🔍 fetchGroupDevices DEBUG pour group $groupId:');
    debugPrint('  - raw devices count: ${raw.length}');
    for (int i = 0; i < raw.length; i++) {
      final device = raw[i];
      debugPrint('    Device $i: ${device['userId']}/${device['deviceId']}');
      debugPrint('      - pk_sig length: ${(device['pk_sig'] as String).length}');
      debugPrint('      - pk_kem length: ${(device['pk_kem'] as String).length}');
      debugPrint('      - status: ${device['status']}');
    }
    
    final entries = raw.map((e) => GroupDeviceKeyEntry.fromJson(e)).toList();
    _cache[groupId] = entries;
    debugPrint('🔐 KeyDirectory cache updated for group $groupId: ${entries.length} devices');
    return entries;
  }

  /// Retourne les entrées en cache si dispo, sinon fetch
  Future<List<GroupDeviceKeyEntry>> getGroupDevices(String groupId) async {
    final cached = _cache[groupId];
    if (cached != null) return cached;
    return fetchGroupDevices(groupId);
  }

  /// Helper: filtre par liste d'utilisateurs; retourne toutes leurs devices actives
  Future<List<GroupDeviceKeyEntry>> devicesForUsers(String groupId, List<String> userIds) async {
    final all = await getGroupDevices(groupId);
    final set = userIds.toSet();
    return all.where((e) => set.contains(e.userId) && e.status == 'active').toList();
  }
}


