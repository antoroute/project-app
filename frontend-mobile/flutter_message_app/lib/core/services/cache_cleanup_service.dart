import 'dart:async';
import 'package:flutter/foundation.dart';
import 'message_key_cache.dart';
import 'persistent_message_key_cache.dart';
import '../providers/conversation_provider.dart';

/// Service centralisé pour le nettoyage automatique des caches
/// 
/// Exécute un nettoyage périodique de tous les caches de l'application
/// pour prévenir les fuites mémoire et maintenir des performances stables.
class CacheCleanupService {
  CacheCleanupService._internal();
  static final CacheCleanupService instance = CacheCleanupService._internal();
  
  Timer? _cleanupTimer;
  bool _isRunning = false;
  ConversationProvider? _conversationProvider;
  
  /// Intervalle de nettoyage (par défaut: 1 heure)
  static const Duration _cleanupInterval = Duration(hours: 1);
  
  /// Enregistre le ConversationProvider pour le nettoyage
  void registerConversationProvider(ConversationProvider provider) {
    _conversationProvider = provider;
    debugPrint('📝 [CacheCleanup] ConversationProvider enregistré');
  }
  
  /// Démarre le nettoyage automatique périodique
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    
    debugPrint('🧹 [CacheCleanup] Démarrage du nettoyage automatique (intervalle: ${_cleanupInterval.inHours}h)');
    
    // Nettoyer immédiatement au démarrage
    _performCleanup().catchError((e) {
      debugPrint('⚠️ [CacheCleanup] Erreur nettoyage initial: $e');
    });
    
    // Programmer le nettoyage périodique
    _cleanupTimer = Timer.periodic(_cleanupInterval, (_) {
      _performCleanup().catchError((e) {
        debugPrint('⚠️ [CacheCleanup] Erreur nettoyage périodique: $e');
      });
    });
  }
  
  /// Arrête le nettoyage automatique
  void stop() {
    _isRunning = false;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    debugPrint('🛑 [CacheCleanup] Nettoyage automatique arrêté');
  }
  
  /// Effectue le nettoyage de tous les caches
  Future<void> _performCleanup() async {
    debugPrint('🧹 [CacheCleanup] Début du nettoyage périodique...');
    final startTime = DateTime.now();
    
    try {
      // 1. Nettoyer MessageKeyCache (mémoire) - le nettoyage se fait automatiquement
      // via _cleanupIfNeeded() qui est appelé lors des opérations
      // Pas besoin de nettoyage manuel pour le cache mémoire
      
      // 2. Nettoyer PersistentMessageKeyCache (cache persistant des message keys)
      try {
        await PersistentMessageKeyCache.instance.cleanupExpiredKeys();
      } catch (e) {
        debugPrint('⚠️ [CacheCleanup] Erreur nettoyage PersistentMessageKeyCache: $e');
      }
      
      // 3. Nettoyer KeyDirectoryService (cache persistant des group keys)
      if (_conversationProvider != null) {
        try {
          await _conversationProvider!.keyDirectory.cleanupExpiredKeys();
        } catch (e) {
          debugPrint('⚠️ [CacheCleanup] Erreur nettoyage KeyDirectoryService: $e');
        }
      }
      
      final duration = DateTime.now().difference(startTime);
      debugPrint('✅ [CacheCleanup] Nettoyage terminé en ${duration.inMilliseconds}ms');
    } catch (e) {
      debugPrint('❌ [CacheCleanup] Erreur lors du nettoyage: $e');
    }
  }
  
  /// Force un nettoyage immédiat (pour tests ou situations spéciales)
  Future<void> cleanupNow() async {
    await _performCleanup();
  }
  
  /// Obtient les statistiques de tous les caches
  Map<String, dynamic> getStats() {
    return {
      'message_key_cache': MessageKeyCache.instance.getStats(),
      // Ajouter autres caches...
    };
  }
}

