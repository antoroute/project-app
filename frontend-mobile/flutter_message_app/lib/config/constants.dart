import 'package:flutter_dotenv/flutter_dotenv.dart';

const String apiBase = "https://api.kavalek.fr";
const String messagingBase = "https://api.kavalek.fr/api";
const String authBase = "https://auth.kavalek.fr/auth";
const String socketBase = "https://api.kavalek.fr";
const String clientVersion = "2.0.0";

const int maxEmailCharacters = 254;
const int maxUsernameCharacters = 64;
const int minPasswordCharacters = 8;
const int maxPasswordCharacters = 1024;
const int maxGroupNameCharacters = 64;
const int maxConversationParticipants = 128;
const int maxMessageRecipients = 256;
const int maxMessagePlaintextBytes = 65520; // 64 Kio moins le tag AES-GCM.
const int maxSocketBatchConversations = 100;

/// Valeur partagée transitoire, distincte des secrets JWT exclusivement serveur.
/// Son embarquement et son fallback sont des vulnérabilités connues à supprimer dans TC-109.
String get appSecret =>
    dotenv.env['APP_SECRET'] ?? 'kavalek_app_2024_secure_secret_key_v2';
