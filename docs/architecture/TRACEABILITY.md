# Matrice de traçabilité fonctionnelle et sécurité

Dernière mise à jour : 2026-08-24
Code observé : `25d0f657763036e90acad27f16f33f4cda369f31`

Cette matrice aide à retrouver rapidement le code réellement responsable d'un comportement. Elle n'atteste ni la qualité ni la sécurité d'une fonction : consulter la référence fonctionnelle, les invariants et les tâches liées avant toute modification.

## Client Flutter

| Domaine | Entrées principales | Stockage/transport | Risques ou travail lié |
|---|---|---|---|
| démarrage et injection | [`main.dart`](../../frontend-mobile/flutter_message_app/lib/main.dart) | secure storage, SQLite, Socket.IO | `TC-601`, `TC-602` |
| configuration des URL et en-têtes | [`constants.dart`](../../frontend-mobile/flutter_message_app/lib/config/constants.dart), [`api_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/api_service.dart) | HTTPS | `TC-109`, configuration release |
| inscription, connexion, refresh, sortie | [`auth_provider.dart`](../../frontend-mobile/flutter_message_app/lib/core/providers/auth_provider.dart), [`biometric_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/biometric_service.dart) | secure storage, Auth API | `TC-401` à `TC-408` ; logout distant manquant |
| identifiant d'appareil | [`session_device_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/session_device_service.dart) | secure storage | `TC-303`, `TC-306` |
| génération et stockage des clés | [`key_manager_final.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/key_manager_final.dart) | secure storage | `TC-106`, `TC-303`, `TC-306` |
| annuaire de clés publiques | [`key_directory_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/key_directory_service.dart) | Messaging API, cache mémoire | `TC-106`, `TC-303` |
| enveloppe E2EE V2 | [`message_cipher_v2.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/message_cipher_v2.dart), [`message_envelope_verifier.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/message_envelope_verifier.dart), [`message_v2.dart`](../../frontend-mobile/flutter_message_app/lib/core/models/message_v2.dart) | JSON V2 | `TC-114`, `TC-301` à `TC-312` |
| calculs cryptographiques hors UI | [`crypto_isolate_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/crypto_isolate_service.dart), [`crypto_isolate_worker.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/crypto_isolate_worker.dart) | isolates Flutter | `TC-114`, tests performance |
| orchestration messages/conversations | [`conversation_provider.dart`](../../frontend-mobile/flutter_message_app/lib/core/providers/conversation_provider.dart) | REST, Socket.IO, caches | `TC-104`, `TC-105`, `TC-114`, Phase 5 |
| cercles et adhésion | [`group_provider.dart`](../../frontend-mobile/flutter_message_app/lib/core/providers/group_provider.dart) | Messaging API | `TC-104` à `TC-107`, `TC-607` |
| WebSocket | [`websocket_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/websocket_service.dart), [`websocket_heartbeat_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/websocket_heartbeat_service.dart) | Socket.IO | `TC-108`, `TC-505`, `TC-510` |
| présence | [`global_presence_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/global_presence_service.dart) | Socket.IO, mémoire | `TC-510` |
| enveloppes locales | [`local_message_storage.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/local_message_storage.dart) | SQLite non chiffré | `TC-306`, Phase 5 |
| clés de message en mémoire | [`message_key_cache.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/message_key_cache.dart) | RAM, accès après preuve typée | `TC-114`, `TC-306` |
| clés de message persistantes | [`persistent_message_key_cache.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/persistent_message_key_cache.dart) | secure storage + SQLite | `TC-306` ; génération de clé critique |
| queue hors ligne | [`message_queue_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/message_queue_service.dart) | SQLite | `TC-502` ; non intégrée au chemin d'envoi |
| notifications locales | [`notification_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/notification_service.dart), [`in_app_notification_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/in_app_notification_service.dart) | OS/RAM | `TC-114`, `TC-509` |
| réseau et reprise | [`network_monitor_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/network_monitor_service.dart) | connectivité | `TC-504` à `TC-508` |

## Écrans et parcours

| Parcours | Écrans principaux | État observé |
|---|---|---|
| authentification | [`login_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/login_screen.dart), [`register_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/register_screen.dart) | connexion/inscription présentes ; récupération et vérification absentes |
| accueil et navigation | [`home_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/home_screen.dart), [`main_nav_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/main_nav_screen.dart) | mobile prioritaire, portrait imposé |
| cercles | [`group_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/group_screen.dart), [`group_nav_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/group_nav_screen.dart), [`group_detail_info_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/group_detail_info_screen.dart) | création, liste, détail et membres partiels |
| adhésion | [`qr_scan_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/qr_scan_screen.dart), [`join_requests_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/join_requests_screen.dart) | identifiant brut et décision créateur/legacy |
| conversations | [`group_conversation_list.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/group_conversation_list.dart), [`conversation_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/conversation_screen.dart) | texte V2, présence, frappe, lecture |
| appareils | [`my_devices_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/my_devices_screen.dart) | liste/révocation partielles |
| calendrier/carte | [`group_calendar_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/group_calendar_screen.dart), [`group_map_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/group_map_screen.dart) | factices, hors V1 |

## Backend Auth

| Responsabilité | Code | Données | Tâches |
|---|---|---|---|
| démarrage/configuration | [`index.ts`](../../backend/auth/src/index.ts), [`config.ts`](../../backend/auth/src/config.ts) | variables d'environnement | `TC-101`, `TC-108` |
| routes compte/session | [`auth.ts`](../../backend/auth/src/routes/auth.ts) | `users`, `refresh_tokens` | `TC-102`, `TC-401` à `TC-408` |
| JWT access/refresh | [`jwt.ts`](../../backend/auth/src/security/jwt.ts) | Ed25519/HS256 | `TC-102` terminé |
| faux secret d'application | [`validateAppSecret.ts`](../../backend/auth/src/middlewares/validateAppSecret.ts) | en-tête client | `TC-109` |
| version minimale | [`enforceVersion.ts`](../../backend/auth/src/middlewares/enforceVersion.ts) | en-têtes | `TC-107` |
| PostgreSQL | [`db.ts`](../../backend/auth/src/plugins/db.ts) | pool SQL | `TC-201`, `TC-203` |

## Backend Messaging

| Responsabilité | Code | Données/événements | Tâches |
|---|---|---|---|
| serveur HTTP et Socket.IO | [`index.ts`](../../backend/messaging/src/index.ts) | événements temps réel | `TC-108`, `TC-505`, `TC-510` |
| configuration | [`config.ts`](../../backend/messaging/src/config.ts) | variables d'environnement | `TC-101`, `TC-108` |
| validation JWT HTTP/socket | [`jwt.ts`](../../backend/messaging/src/security/jwt.ts), [`socketAuth.ts`](../../backend/messaging/src/middlewares/socketAuth.ts) | JWT access public-key-only | `TC-102` terminé |
| cercles/adhésion | [`groups.ts`](../../backend/messaging/src/routes/groups.ts) | `groups`, `user_groups`, demandes/votes | `TC-104`, `TC-105`, `TC-107` |
| appareils et clés publiques | [`keys.devices.ts`](../../backend/messaging/src/routes/keys.devices.ts) | `group_device_keys` | `TC-106`, `TC-107` |
| conversations | [`conversations.ts`](../../backend/messaging/src/routes/conversations.ts) | `conversations`, `conversation_users` | `TC-104`, `TC-105`, `TC-107` |
| messages V2 | [`messages.v2.ts`](../../backend/messaging/src/routes/messages.v2.ts), [`messageV2.schema.ts`](../../backend/messaging/src/schemas/messageV2.schema.ts) | `messages`, `message:new` | `TC-103` terminé, `TC-104`, `TC-107`, Phase 5 |
| contrôles d'accès partagés | [`acl.ts`](../../backend/messaging/src/services/acl.ts) | groupes/conversations | `TC-104` |
| présence | [`presence.ts`](../../backend/messaging/src/services/presence.ts) | mémoire processus | `TC-205`, `TC-510` |

## Données PostgreSQL observées

| Table | Contenu principal | Sensibilité | Évolution |
|---|---|---|---|
| `users` | compte et mot de passe haché | très élevée | Phase 4 |
| `refresh_tokens` | empreinte de refresh et expiration | très élevée | `TC-102`, Phase 4 |
| `groups`, `user_groups` | cercles et adhésions | élevée | `TC-104`, `TC-201` |
| `group_keys` | clé publique historique de cercle | moyenne | migration V3 |
| `group_device_keys` | clés publiques et état des appareils | élevée | `TC-106`, Phase 3 |
| `join_requests`, `join_request_votes` | demandes et décisions | élevée | `TC-104`, `TC-607` |
| `conversations`, `conversation_users` | conversations et participants | élevée | `TC-104`, `TC-105` |
| `messages` | enveloppes E2EE et métadonnées | très élevée | Phases 3 et 5 |
| `notifications` | notifications backend historiques | élevée | `TC-509`, rétention |

Le modèle exact observé et ses incohérences sont détaillés dans [`DATA_MODEL.md`](DATA_MODEL.md).

## Documentation de référence

| Besoin | Document |
|---|---|
| comprendre les parcours complets | [`FUNCTIONAL_REFERENCE.md`](FUNCTIONAL_REFERENCE.md) |
| comprendre chaque octet du chiffrement V2 | [`CRYPTOGRAPHY_V2.md`](../security/CRYPTOGRAPHY_V2.md) |
| connaître les règles non négociables | [`SECURITY_INVARIANTS.md`](../security/SECURITY_INVARIANTS.md) |
| comprendre les adversaires et impacts | [`THREAT_MODEL.md`](../security/THREAT_MODEL.md) |
| connaître la cible cryptographique | [`ADR-0003-protocole-crypto-v3.md`](../adr/ADR-0003-protocole-crypto-v3.md) |
| sélectionner la prochaine tâche | [`ROADMAP.md`](../roadmap/ROADMAP.md) |

## Règle de maintenance

Une modification de route, événement, table, clé, format E2EE ou ordre de vérification doit mettre à jour cette matrice et le document spécialisé dans le même changement. Une référence « observée » ne devient une garantie qu'après tests et preuve attachés à la tâche correspondante.
