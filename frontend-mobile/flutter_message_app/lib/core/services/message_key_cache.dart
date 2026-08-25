import 'package:flutter/foundation.dart';
import 'package:flutter_message_app/core/crypto/message_envelope_verifier.dart';
import 'package:flutter_message_app/core/services/persistent_message_key_cache.dart';

/// Cache des clés de message déjà authentifiées et ouvertes avec succès.
class MessageKeyCache {
  MessageKeyCache._internal();

  static final MessageKeyCache instance = MessageKeyCache._internal();

  final Map<String, _CachedMessageKey> _cache = {};

  static const Duration _defaultTtl = Duration(hours: 24);
  static const int _maxCacheSize = 1000;

  /// Consulte les caches seulement après présentation d'une preuve typée
  /// produite par [MessageEnvelopeVerifier].
  Future<Uint8List?> getVerifiedMessageKey(
    VerifiedMessageEnvelope envelope,
  ) async {
    final cacheKey = _cacheKey(envelope);
    final memoryKey = _getMemoryMessageKey(cacheKey);
    if (memoryKey != null) {
      return memoryKey;
    }

    final persistentKey = await PersistentMessageKeyCache.instance
        .getMessageKey(
          messageId: envelope.messageId,
          userId: envelope.recipientUserId,
          deviceId: envelope.recipientDeviceId,
        );
    if (persistentKey == null || persistentKey.length != 32) {
      return null;
    }

    _cache[cacheKey] = _CachedMessageKey(
      key: Uint8List.fromList(persistentKey),
      timestamp: DateTime.now(),
      ttl: _defaultTtl,
    );
    _cleanupIfNeeded();
    return Uint8List.fromList(persistentKey);
  }

  /// Stocke une clé uniquement après vérification Ed25519 et ouverture réussie
  /// du tag AES-GCM du contenu.
  Future<void> cacheVerifiedMessageKey({
    required VerifiedMessageEnvelope envelope,
    required Uint8List messageKey,
  }) async {
    if (messageKey.length != 32) {
      throw const MessageAuthenticationException('invalid_message_key');
    }

    _cache[_cacheKey(envelope)] = _CachedMessageKey(
      key: Uint8List.fromList(messageKey),
      timestamp: DateTime.now(),
      ttl: _defaultTtl,
    );
    _cleanupIfNeeded();

    try {
      await PersistentMessageKeyCache.instance.saveMessageKey(
        messageId: envelope.messageId,
        groupId: envelope.groupId,
        userId: envelope.recipientUserId,
        deviceId: envelope.recipientDeviceId,
        messageKey: messageKey,
        derivedFromDevice: envelope.senderDeviceId,
      );
    } catch (_) {
      debugPrint('Cache persistant de clé indisponible');
    }
  }

  String _cacheKey(VerifiedMessageEnvelope envelope) =>
      '${envelope.recipientUserId}\u0000${envelope.recipientDeviceId}\u0000${envelope.messageId}';

  Uint8List? _getMemoryMessageKey(String cacheKey) {
    final cached = _cache[cacheKey];
    if (cached == null) {
      return null;
    }
    if (cached.isExpired) {
      _cache.remove(cacheKey);
      return null;
    }
    return Uint8List.fromList(cached.key);
  }

  void _cleanupIfNeeded() {
    _cache.removeWhere((_, value) => value.isExpired);
    if (_cache.length <= _maxCacheSize) {
      return;
    }

    final sorted =
        _cache.entries.toList()
          ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
    for (final entry in sorted.take(_cache.length - _maxCacheSize)) {
      _cache.remove(entry.key);
    }
  }

  void clear() {
    _cache.clear();
  }

  Map<String, dynamic> getStats() => {
    'total_cached': _cache.length,
    'active_keys': _cache.values.where((value) => !value.isExpired).length,
    'max_size': _maxCacheSize,
  };
}

class _CachedMessageKey {
  _CachedMessageKey({
    required this.key,
    required this.timestamp,
    required this.ttl,
  });

  final Uint8List key;
  final DateTime timestamp;
  final Duration ttl;

  bool get isExpired => DateTime.now().difference(timestamp) > ttl;
}
