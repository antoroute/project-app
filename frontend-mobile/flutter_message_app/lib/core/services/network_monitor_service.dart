import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

/// Service pour surveiller l'état de la connexion réseau
class NetworkMonitorService {
  static final NetworkMonitorService _instance = NetworkMonitorService._internal();
  factory NetworkMonitorService() => _instance;
  NetworkMonitorService._internal();

  final Connectivity _connectivity = Connectivity();
  final StreamController<bool> _networkStatusController = StreamController<bool>.broadcast();
  
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _isConnected = true;
  bool _isInitialized = false;

  /// Stream pour écouter les changements de connectivité
  Stream<bool> get networkStatusStream => _networkStatusController.stream;
  
  /// Vérifie si le réseau est disponible
  bool get isConnected => _isConnected;

  /// Initialise le service de surveillance réseau
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    // Vérifier l'état initial
    await _checkConnectivity();
    
    // Écouter les changements de connectivité
    _subscription = _connectivity.onConnectivityChanged.listen(
      (List<ConnectivityResult> results) {
        _updateConnectivity(results);
      },
    );
    
    _isInitialized = true;
    debugPrint('🌐 [NetworkMonitor] Service initialisé');
  }

  /// Vérifie l'état actuel de la connectivité
  Future<void> _checkConnectivity() async {
    try {
      final results = await _connectivity.checkConnectivity();
      _updateConnectivity(results);
    } catch (e) {
      debugPrint('❌ [NetworkMonitor] Erreur vérification connectivité: $e');
      _isConnected = false;
      _networkStatusController.add(false);
    }
  }

  /// Met à jour l'état de connectivité
  void _updateConnectivity(List<ConnectivityResult> results) {
    final wasConnected = _isConnected;
    
    // Considérer connecté si on a au moins un type de connexion (wifi, mobile, ethernet)
    _isConnected = results.any((result) => 
      result != ConnectivityResult.none
    );
    
    if (wasConnected != _isConnected) {
      debugPrint('🌐 [NetworkMonitor] État réseau changé: ${_isConnected ? "Connecté" : "Déconnecté"}');
      _networkStatusController.add(_isConnected);
    }
  }

  /// Vérifie si on a une connexion Internet (pas seulement réseau local)
  Future<bool> hasInternetConnection() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return results.any((result) => result != ConnectivityResult.none);
    } catch (e) {
      debugPrint('❌ [NetworkMonitor] Erreur vérification Internet: $e');
      return false;
    }
  }

  /// Dispose le service
  void dispose() {
    _subscription?.cancel();
    _networkStatusController.close();
    _isInitialized = false;
    debugPrint('🌐 [NetworkMonitor] Service disposé');
  }
}

