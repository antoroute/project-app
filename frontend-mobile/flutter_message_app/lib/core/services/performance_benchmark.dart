import 'dart:async';
import 'package:flutter/foundation.dart';

/// Service de benchmarking pour mesurer les performances
/// Utilisé pour évaluer l'efficacité des optimisations
class PerformanceBenchmark {
  PerformanceBenchmark._internal();
  static final PerformanceBenchmark instance = PerformanceBenchmark._internal();
  
  // Stockage des métriques
  final Map<String, List<Duration>> _metrics = {};
  final Map<String, DateTime> _activeTimers = {};
  
  /// Démarre un timer pour une opération
  String startTimer(String operationName) {
    final timerId = '${operationName}_${DateTime.now().millisecondsSinceEpoch}';
    _activeTimers[timerId] = DateTime.now();
    debugPrint('⏱️ [BENCHMARK] Début: $operationName (ID: $timerId)');
    return timerId;
  }
  
  /// Arrête un timer et enregistre la durée
  void stopTimer(String timerId, {String? customName}) {
    final startTime = _activeTimers.remove(timerId);
    if (startTime == null) {
      debugPrint('⚠️ [BENCHMARK] Timer $timerId non trouvé');
      return;
    }
    
    final duration = DateTime.now().difference(startTime);
    final operationName = customName ?? timerId.split('_').first;
    
    _metrics.putIfAbsent(operationName, () => []);
    _metrics[operationName]!.add(duration);
    
    debugPrint('⏱️ [BENCHMARK] Fin: $operationName = ${duration.inMilliseconds}ms (ID: $timerId)');
  }
  
  /// Mesure une opération async
  Future<T> measureAsync<T>(
    String operationName,
    Future<T> Function() operation,
  ) async {
    final timerId = startTimer(operationName);
    try {
      final result = await operation();
      stopTimer(timerId);
      return result;
    } catch (e) {
      stopTimer(timerId);
      rethrow;
    }
  }
  
  /// Mesure une opération sync
  T measureSync<T>(
    String operationName,
    T Function() operation,
  ) {
    final timerId = startTimer(operationName);
    try {
      final result = operation();
      stopTimer(timerId);
      return result;
    } catch (e) {
      stopTimer(timerId);
      rethrow;
    }
  }
  
  /// Obtient les statistiques pour une opération
  Map<String, dynamic> getStats(String operationName) {
    final durations = _metrics[operationName];
    if (durations == null || durations.isEmpty) {
      return {
        'operation': operationName,
        'count': 0,
        'error': 'No data',
      };
    }
    
    durations.sort((a, b) => a.compareTo(b));
    
    final total = durations.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    final avg = total / durations.length;
    final min = durations.first.inMilliseconds;
    final max = durations.last.inMilliseconds;
    final median = durations[durations.length ~/ 2].inMilliseconds;
    final p95 = durations[(durations.length * 0.95).floor()].inMilliseconds;
    final p99 = durations[(durations.length * 0.99).floor()].inMilliseconds;
    
    return {
      'operation': operationName,
      'count': durations.length,
      'total_ms': total,
      'avg_ms': avg.toStringAsFixed(2),
      'min_ms': min,
      'max_ms': max,
      'median_ms': median,
      'p95_ms': p95,
      'p99_ms': p99,
    };
  }
  
  /// Obtient toutes les statistiques
  Map<String, Map<String, dynamic>> getAllStats() {
    final stats = <String, Map<String, dynamic>>{};
    for (final operationName in _metrics.keys) {
      stats[operationName] = getStats(operationName);
    }
    return stats;
  }
  
  /// Affiche un rapport complet
  void printReport() {
    debugPrint('\n📊 ========== RAPPORT DE PERFORMANCE ==========');
    final stats = getAllStats();
    
    if (stats.isEmpty) {
      debugPrint('Aucune donnée collectée');
      return;
    }
    
    // Trier par nombre d'appels (plus fréquent en premier)
    final sorted = stats.entries.toList()
      ..sort((a, b) => (b.value['count'] as int).compareTo(a.value['count'] as int));
    
    for (final entry in sorted) {
      final stat = entry.value;
      debugPrint('\n📈 ${stat['operation']}:');
      debugPrint('   Appels: ${stat['count']}');
      debugPrint('   Total: ${stat['total_ms']}ms');
      debugPrint('   Moyenne: ${stat['avg_ms']}ms');
      debugPrint('   Min: ${stat['min_ms']}ms | Max: ${stat['max_ms']}ms');
      debugPrint('   Médiane: ${stat['median_ms']}ms');
      debugPrint('   P95: ${stat['p95_ms']}ms | P99: ${stat['p99_ms']}ms');
    }
    
    debugPrint('\n📊 ===========================================\n');
  }
  
  /// Nettoie les métriques
  void clear() {
    _metrics.clear();
    _activeTimers.clear();
    debugPrint('🧹 [BENCHMARK] Métriques nettoyées');
  }
  
  /// Nettoie les métriques pour une opération spécifique
  void clearOperation(String operationName) {
    _metrics.remove(operationName);
    debugPrint('🧹 [BENCHMARK] Métriques nettoyées pour: $operationName');
  }
}

