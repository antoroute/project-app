import 'dart:collection';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' show sha256;

/// Entrée dans le cache LRU
class _CacheEntry {
  final String messageId;
  final String cipherHash;
  final String plaintext;
  final DateTime timestamp;
  
  _CacheEntry(this.messageId, this.cipherHash, this.plaintext, this.timestamp);
}

/// Cache LRU pour les messages déchiffrés
class DecryptionCache {
  final int capacity;
  final Duration ttl; // Time To Live
  final _map = LinkedHashMap<String, _CacheEntry>();

  DecryptionCache({
    this.capacity = 500,
    this.ttl = const Duration(hours: 24),
  });

  /// Génère un hash unique pour le couple (iv, cipher)
  static String hashCipher(Uint8List iv, Uint8List cipher) {
    final bytes = <int>[]..addAll(iv)..addAll(cipher);
    return sha256.convert(bytes).toString();
  }

  /// Récupère un message déchiffré du cache
  String? get(String messageId, String cipherHash) {
    final entry = _map[messageId];
    if (entry == null || entry.cipherHash != cipherHash) return null;
    
    // Vérifier la TTL
    if (DateTime.now().difference(entry.timestamp) > ttl) {
      _map.remove(messageId);
      return null;
    }
    
    // Bump LRU (déplacer en fin de liste)
    _map.remove(messageId);
    _map[messageId] = entry;
    return entry.plaintext;
  }

  /// Met un message déchiffré en cache
  void put(String messageId, String cipherHash, String plaintext) {
    // Éviction LRU si nécessaire
    if (_map.length >= capacity && !_map.containsKey(messageId)) {
      _map.remove(_map.keys.first);
    }
    
    _map[messageId] = _CacheEntry(messageId, cipherHash, plaintext, DateTime.now());
  }

  /// Nettoie les entrées expirées
  void cleanup() {
    final now = DateTime.now();
    final expiredKeys = <String>[];
    
    for (final entry in _map.entries) {
      if (now.difference(entry.value.timestamp) > ttl) {
        expiredKeys.add(entry.key);
      }
    }
    
    for (final key in expiredKeys) {
      _map.remove(key);
    }
  }

  /// Vide le cache
  void clear() {
    _map.clear();
  }

  /// Retourne les statistiques du cache
  Map<String, dynamic> getStats() {
    return {
      'size': _map.length,
      'capacity': capacity,
      'ttl_hours': ttl.inHours,
    };
  }
}
