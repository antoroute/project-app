import 'package:flutter_dotenv/flutter_dotenv.dart';

const String apiBase = "https://api.kavalek.fr";
const String messagingBase = "https://api.kavalek.fr/api";
const String authBase = "https://auth.kavalek.fr/auth";
const String socketBase = "https://api.kavalek.fr";
const String clientVersion = "2.0.0";

/// Valeur partagée transitoire, distincte des secrets JWT exclusivement serveur.
/// Son embarquement et son fallback sont des vulnérabilités connues à supprimer dans TC-109.
String get appSecret => dotenv.env['APP_SECRET'] ?? 'kavalek_app_2024_secure_secret_key_v2';
