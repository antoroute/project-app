import 'package:flutter_dotenv/flutter_dotenv.dart';

const String apiBase = "https://api.kavalek.fr";
const String messagingBase = "https://api.kavalek.fr/api";
const String authBase = "https://auth.kavalek.fr/auth";
const String socketBase = "https://api.kavalek.fr";
const String clientVersion = "2.0.0";

/// 🔐 App Secret pour sécuriser l'API
/// Chargé depuis la variable d'environnement APP_SECRET (comme AUTH_JWT_SECRET)
/// Si non définie, utilise une valeur par défaut pour le développement
/// ⚠️ En production, définissez APP_SECRET dans votre fichier .env
String get appSecret => dotenv.env['APP_SECRET'] ?? 'kavalek_app_2024_secure_secret_key_v2';