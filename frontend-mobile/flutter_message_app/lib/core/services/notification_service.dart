import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service de gestion des notifications push et in-app
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Initialise le service de notifications
  static Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    _initialized = true;
    debugPrint('🔔 Service de notifications initialisé');
  }

  /// Gère le tap sur une notification
  static void _onNotificationTapped(NotificationResponse response) {
    debugPrint('🔔 Notification tapée: ${response.payload}');
    // TODO: Naviguer vers la conversation appropriée
  }

  /// Affiche une notification pour un nouveau message
  static Future<void> showMessageNotification({
    required String title,
    required String body,
    required String conversationId,
    String? senderName,
  }) async {
    if (!_initialized) {
      debugPrint('⚠️ Service de notifications non initialisé');
      return;
    }

    const androidDetails = AndroidNotificationDetails(
      'messages',
      'Messages Channel',
      channelDescription: 'Notifications pour les nouveaux messages',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(
      conversationId.hashCode, // ID unique basé sur la conversation
      title,
      body,
      details,
      payload: conversationId, // Payload pour navigation
    );

    debugPrint('🔔 Notification affichée: $title - $body');
  }

  /// Affiche une notification générique
  static Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) {
      debugPrint('⚠️ Service de notifications non initialisé');
      return;
    }

    const androidDetails = AndroidNotificationDetails(
      'general',
      'General Channel',
      channelDescription: 'Notifications générales',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      details,
      payload: payload,
    );

    debugPrint('🔔 Notification générale affichée: $title - $body');
  }

  /// Annule toutes les notifications
  static Future<void> cancelAll() async {
    await _notifications.cancelAll();
    debugPrint('🔔 Toutes les notifications annulées');
  }

  /// Annule les notifications pour une conversation spécifique
  static Future<void> cancelConversationNotifications(String conversationId) async {
    await _notifications.cancel(conversationId.hashCode);
    debugPrint('🔔 Notifications annulées pour la conversation: $conversationId');
  }

  /// Vérifie si les notifications sont activées
  static Future<bool> areNotificationsEnabled() async {
    if (!_initialized) return false;
    
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      return await androidPlugin.areNotificationsEnabled() ?? false;
    }
    
    // Pour iOS, on assume que c'est activé si on peut initialiser
    return true;
  }

  /// Demande les permissions de notification
  static Future<bool> requestPermissions() async {
    if (!_initialized) return false;
    
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      return await androidPlugin.requestNotificationsPermission() ?? false;
    }
    
    return true;
  }
}
