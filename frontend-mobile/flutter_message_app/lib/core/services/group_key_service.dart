import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class GroupKeyService {
  static final GroupKeyService instance = GroupKeyService._internal();
  factory GroupKeyService() => instance;
  GroupKeyService._internal();

  final _storage = const FlutterSecureStorage();

  String _groupKeyPrefix(String? groupId) => 'group_keys_${groupId ?? 'new_group'}_v2';

  Future<void> _storeString(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  Future<String> _loadString(String key) async {
    final value = await _storage.read(key: key);
    if (value == null) throw Exception('Group key not found for $key');
    return value;
  }

  Future<String> getGroupSigningPublicKeyB64(String? groupId) async {
    final key = '${_groupKeyPrefix(groupId)}_ed25519_public';
    
    try {
      return await _loadString(key);
    } catch (_) {
      // Générer une nouvelle paire si elle n'existe pas
      final keyPair = await Ed25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final publicKeyB64 = base64.encode(publicKey.bytes);
      
      // Stocker la clé publique
      await _storeString(key, publicKeyB64);
      
      return publicKeyB64;
    }
  }

  Future<String> getGroupKEMPublicKeyB64(String? groupId) async {
    final key = '${_groupKeyPrefix(groupId)}_x25519_public';
    
    try {
      return await _loadString(key);
    } catch (_) {
      // Générer une nouvelle paire si elle n'existe pas
      final keyPair = await X25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final publicKeyB64 = base64.encode(publicKey.bytes);
      
      // Stocker la clé publique
      await _storeString(key, publicKeyB64);
      
      return publicKeyB64;
    }
  }

  Future<void> clearGroupKeys(String groupId) async {
    final sigKey = '${_groupKeyPrefix(groupId)}_ed25519_public';
    final kemKey = '${_groupKeyPrefix(groupId)}_x25519_public';
    await _storage.delete(key: sigKey);
    await _storage.delete(key: kemKey);
  }
}