import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import '../services/decryption_worker.dart';
import '../services/decryption_cache.dart';

/// Service de gestion des messages déchiffrés avec cache et Isolate
class DecryptedMessageService extends ChangeNotifier {
  final _worker = DecryptionWorker();
  final _cache = DecryptionCache(capacity: 600);
  
  final Map<String, ValueNotifier<String?>> _notifiers = {};
  StreamSubscription? _subscription;
  
  // Statistiques
  int _totalRequests = 0;
  int _cacheHits = 0;
  int _decryptionErrors = 0;

  DecryptedMessageService() {
    _subscription = _worker.resultStream.listen(_onDecryptResult);
    
    // Nettoyage périodique du cache
    Timer.periodic(const Duration(minutes: 30), (_) => _cache.cleanup());
  }

  /// Écoute les résultats de déchiffrement
  void _onDecryptResult(DecryptResult result) {
    final notifier = _notifiers[result.messageId];
    if (notifier == null) return;
    
    if (result.plaintext != null) {
      notifier.value = result.plaintext;
    } else if (result.error != null) {
      notifier.value = '[Erreur déchiffrement]';
      _decryptionErrors++;
      debugPrint('❌ Erreur déchiffrement message ${result.messageId}: ${result.error}');
    }
  }

  /// Retourne un ValueListenable pour un message spécifique
  ValueListenable<String?> listenTo(String messageId) {
    return _notifiers.putIfAbsent(messageId, () => ValueNotifier<String?>(null));
  }

  /// Demande le déchiffrement d'un message
  Future<void> request({
    required String messageId,
    required Uint8List iv,
    required Uint8List cipher,
    required Uint8List aesKey,
    String algorithm = 'AES-256-GCM',
  }) async {
    _totalRequests++;
    
    // Vérifier le cache d'abord
    final hash = DecryptionCache.hashCipher(iv, cipher);
    final cached = _cache.get(messageId, hash);
    
    if (cached != null) {
      _cacheHits++;
      final notifier = _notifiers.putIfAbsent(messageId, () => ValueNotifier<String?>(null));
      notifier.value = cached;
      return;
    }
    
    // Déchiffrement en arrière-plan
    await _worker.decrypt(messageId, aesKey, iv, cipher, algorithm);
  }

  /// Met un message déchiffré en cache
  void cache(String messageId, Uint8List iv, Uint8List cipher, String plaintext) {
    final hash = DecryptionCache.hashCipher(iv, cipher);
    _cache.put(messageId, hash, plaintext);
  }

  /// Préchiffre plusieurs messages (pour les messages visibles)
  Future<void> prefetch(List<Map<String, dynamic>> messages) async {
    final futures = <Future<void>>[];
    
    for (final msg in messages) {
      futures.add(request(
        messageId: msg['id'] as String,
        iv: msg['iv'] as Uint8List,
        cipher: msg['cipher'] as Uint8List,
        aesKey: msg['aesKey'] as Uint8List,
        algorithm: msg['algorithm'] as String? ?? 'AES-256-GCM',
      ));
    }
    
    await Future.wait(futures);
  }

  /// Retourne les statistiques du service
  Map<String, dynamic> getStats() {
    return {
      'total_requests': _totalRequests,
      'cache_hits': _cacheHits,
      'cache_hit_rate': _totalRequests > 0 ? (_cacheHits / _totalRequests * 100).toStringAsFixed(1) + '%' : '0%',
      'decryption_errors': _decryptionErrors,
      'cache_stats': _cache.getStats(),
    };
  }

  /// Nettoie le cache
  void clearCache() {
    _cache.clear();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _worker.dispose();
    super.dispose();
  }
}
