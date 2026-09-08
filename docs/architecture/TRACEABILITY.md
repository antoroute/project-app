# Matrice de traçabilité fonctionnelle et sécurité

Dernière mise à jour : 2026-09-08
Code observé : branche `main`, changement `TC-107`

Cette matrice aide à retrouver rapidement le code réellement responsable d'un comportement. Elle n'atteste ni la qualité ni la sécurité d'une fonction : consulter la référence fonctionnelle, les invariants et les tâches liées avant toute modification.

## Client Flutter

| Domaine | Entrées principales | Stockage/transport | Risques ou travail lié |
|---|---|---|---|
| démarrage et injection | [`main.dart`](../../frontend-mobile/flutter_message_app/lib/main.dart) | secure storage, SQLite, Socket.IO | `TC-601`, `TC-602` |
| configuration des URL, en-têtes et bornes UX | [`constants.dart`](../../frontend-mobile/flutter_message_app/lib/config/constants.dart), [`api_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/api_service.dart) | HTTPS | bornes `TC-107`, `TC-109`, configuration release |
| inscription, connexion, refresh, sortie | [`auth_provider.dart`](../../frontend-mobile/flutter_message_app/lib/core/providers/auth_provider.dart), [`biometric_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/biometric_service.dart) | secure storage, Auth API | `TC-401` à `TC-408` ; logout distant manquant |
| identifiant et identité de compte/appareil | [`session_device_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/session_device_service.dart), [`account_device_identity_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/account_device_identity_service.dart) | secure storage, UUID, seed Ed25519 et preuves d'accès/liaison propres au compte | `TC-106` lots A-D terminés |
| confiance et barrière d'appareil | [`account_device_trust_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/account_device_trust_service.dart), [`auth_provider.dart`](../../frontend-mobile/flutter_message_app/lib/core/providers/auth_provider.dart), [`device_trust_gate_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/device_trust_gate_screen.dart) | Auth/Messaging API, état mémoire | `TC-106` lots C/D terminés |
| génération et stockage des clés | [`key_manager_final.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/key_manager_final.dart), [`secure_string_store.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/secure_string_store.dart) | secure storage, chargement fail-closed et versions historiques | `TC-106` lots A/D, `TC-303`, `TC-306` |
| annuaire de clés publiques | [`key_directory_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/key_directory_service.dart) | Messaging API, cache mémoire/SQLite versionné et invalidation temps réel | `TC-106` lot D, `TC-303` |
| enveloppe E2EE V2 | [`message_cipher_v2.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/message_cipher_v2.dart), [`message_envelope_verifier.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/message_envelope_verifier.dart), [`message_v2.dart`](../../frontend-mobile/flutter_message_app/lib/core/models/message_v2.dart) | JSON V2 | `TC-114`, `TC-301` à `TC-312` |
| calculs cryptographiques hors UI | [`crypto_isolate_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/crypto_isolate_service.dart), [`crypto_isolate_worker.dart`](../../frontend-mobile/flutter_message_app/lib/core/crypto/crypto_isolate_worker.dart) | isolates Flutter | `TC-114`, tests performance |
| orchestration messages/conversations | [`conversation_provider.dart`](../../frontend-mobile/flutter_message_app/lib/core/providers/conversation_provider.dart) | REST, Socket.IO, caches | `TC-104`/`TC-105` terminés, `TC-114`, Phase 5 |
| cercles et adhésion | [`group_provider.dart`](../../frontend-mobile/flutter_message_app/lib/core/providers/group_provider.dart) | Messaging API | `TC-104` à `TC-107`, `TC-607` |
| WebSocket | [`websocket_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/websocket_service.dart), [`websocket_heartbeat_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/websocket_heartbeat_service.dart) | Socket.IO | `TC-108`, `TC-505`, `TC-510` |
| présence | [`global_presence_service.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/global_presence_service.dart) | Socket.IO, mémoire | `TC-510` |
| enveloppes locales | [`local_message_storage.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/local_message_storage.dart) | SQLite non chiffré | `TC-306`, Phase 5 |
| clés de message en mémoire | [`message_key_cache.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/message_key_cache.dart) | RAM, preuve typée et index compte/appareil/message | `TC-106` lot A, `TC-114`, `TC-306` |
| clés de message persistantes | [`persistent_message_key_cache.dart`](../../frontend-mobile/flutter_message_app/lib/core/services/persistent_message_key_cache.dart) | clé maître CSPRNG par compte + SQLite | cloisonnement `TC-106` lot A ; chiffrement SQLite `TC-306` |
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
| appareils du compte | [`account_devices_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/account_devices_screen.dart), [`device_trust_gate_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/device_trust_gate_screen.dart) | attente, liste, empreinte, approbation/refus/révocation signés et rotation |
| appareils historiques par cercle | [`my_devices_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/my_devices_screen.dart) | versions actives/historiques ; révocation redirigée vers la décision globale signée |
| calendrier/carte | [`group_calendar_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/group_calendar_screen.dart), [`group_map_screen.dart`](../../frontend-mobile/flutter_message_app/lib/ui/screens/group_map_screen.dart) | factices, hors V1 |

## Backend Auth

| Responsabilité | Code | Données | Tâches |
|---|---|---|---|
| démarrage/configuration | [`index.ts`](../../backend/auth/src/index.ts), [`config.ts`](../../backend/auth/src/config.ts) | variables d'environnement, corps 16 Kio et objets stricts | `TC-101`, `TC-107`, `TC-108` |
| routes compte/session | [`auth.ts`](../../backend/auth/src/routes/auth.ts) | entrées bornées, `users`, `refresh_tokens` | `TC-102`, `TC-107`, `TC-401` à `TC-408` |
| réautorisation du premier appareil | [`auth.ts`](../../backend/auth/src/routes/auth.ts) | `device_bootstrap_grants`, empreinte SHA-256 | `TC-106` lot B |
| JWT access/refresh | [`jwt.ts`](../../backend/auth/src/security/jwt.ts) | Ed25519/HS256 | `TC-102` terminé |
| faux secret d'application | [`validateAppSecret.ts`](../../backend/auth/src/middlewares/validateAppSecret.ts) | en-tête client | `TC-109` |
| version minimale | [`enforceVersion.ts`](../../backend/auth/src/middlewares/enforceVersion.ts) | en-têtes | `TC-107` |
| PostgreSQL | [`db.ts`](../../backend/auth/src/plugins/db.ts) | pool SQL | `TC-201`, `TC-203` |

## Backend Messaging

| Responsabilité | Code | Données/événements | Tâches |
|---|---|---|---|
| serveur HTTP et Socket.IO | [`index.ts`](../../backend/messaging/src/index.ts), [`input.schema.ts`](../../backend/messaging/src/schemas/input.schema.ts) | corps HTTP 256 Kio, paquets WS 16 Kio, événements entrants stricts | `TC-107` terminé, `TC-108`, `TC-505`, `TC-510` |
| configuration | [`config.ts`](../../backend/messaging/src/config.ts) | variables d'environnement | `TC-101`, `TC-108` |
| validation JWT et appareil HTTP/socket | [`jwt.ts`](../../backend/messaging/src/security/jwt.ts), [`deviceAuth.ts`](../../backend/messaging/src/middlewares/deviceAuth.ts), [`deviceAccess.ts`](../../backend/messaging/src/security/deviceAccess.ts), [`socketAuth.ts`](../../backend/messaging/src/middlewares/socketAuth.ts) | JWT access public-key-only + preuve Ed25519 liée au jti | `TC-102`, `TC-106` lot D |
| transactions PostgreSQL | [`db.ts`](../../backend/messaging/src/plugins/db.ts) | connexion réservée, commit/rollback, retry borné | `TC-105` terminé |
| registre et preuve d'identité d'appareil | [`account.devices.ts`](../../backend/messaging/src/routes/account.devices.ts), [`deviceProof.ts`](../../backend/messaging/src/security/deviceProof.ts) | `account_devices`, challenges, Ed25519 | `TC-106` lot B terminé |
| approbation/refus/révocation d'appareil | [`account.deviceApprovals.ts`](../../backend/messaging/src/routes/account.deviceApprovals.ts), [`deviceApproval.ts`](../../backend/messaging/src/security/deviceApproval.ts) | `device_approval_challenges`, transcription 216 octets, propagation globale | `TC-106` lots C/D terminés |
| cercles/adhésion | [`groups.ts`](../../backend/messaging/src/routes/groups.ts) | `groups`, `user_groups`, demandes/rôles | `TC-104`/`TC-105` terminés, `TC-107` |
| appareils et clés publiques | [`keys.devices.ts`](../../backend/messaging/src/routes/keys.devices.ts), [`groupDeviceKeyBinding.ts`](../../backend/messaging/src/security/groupDeviceKeyBinding.ts) | `group_device_keys`, `group_device_key_history`, événement d'invalidation | atomicité `TC-105`, cycle `TC-106` lot D, validation `TC-107` |
| conversations | [`conversations.ts`](../../backend/messaging/src/routes/conversations.ts) | `conversations`, `conversation_users` | `TC-104`/`TC-105` terminés, `TC-107` |
| messages V2 | [`messages.v2.ts`](../../backend/messaging/src/routes/messages.v2.ts), [`messageV2.schema.ts`](../../backend/messaging/src/schemas/messageV2.schema.ts) | `messages`, `message:new` | `TC-103` à `TC-105` terminés, `TC-107`, Phase 5 |
| matrice et contrôles d'accès partagés | [`acl.ts`](../../backend/messaging/src/services/acl.ts) | rôles, groupes, conversations, clés, Socket.IO | `TC-104`/`TC-105` terminés |
| présence | [`presence.ts`](../../backend/messaging/src/services/presence.ts) | mémoire processus | `TC-205`, `TC-510` |

## Données PostgreSQL observées

| Table | Contenu principal | Sensibilité | Évolution |
|---|---|---|---|
| `users` | compte et mot de passe haché | très élevée | Phase 4 |
| `refresh_tokens` | empreinte de refresh et expiration | très élevée | `TC-102`, Phase 4 |
| `groups`, `user_groups` | cercles et adhésions | élevée | `TC-104`, `TC-201` |
| `group_keys` | clé publique historique de cercle | moyenne | migration V3 |
| `group_device_keys`, `group_device_key_history` | clés publiques courantes signées et versions historiques immuables | élevée | `TC-106` lot D, Phase 3 |
| `device_bootstrap_grants` | empreinte d'autorisation courte, expiration et consommation | très élevée | `TC-106` lot B ; secret brut jamais stocké |
| `account_devices` | clé publique d'identité, plateforme, nom et état de confiance | élevée | `TC-106` lots B-D |
| `device_registration_challenges` | nonce, transcription, expiration et résultat de preuve | élevée | `TC-106` lot B ; rétention 7 jours |
| `device_approval_challenges` | deux identités/version, décision, transcription et résultat | élevée | `TC-106` lot C ; rétention 7 jours |
| `join_requests`, `join_request_votes` | demandes et décisions | élevée | `TC-104`, `TC-607` |
| `conversations`, `conversation_users` | conversations et participants | élevée | ACL et atomicité `TC-104`/`TC-105` terminées |
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
| comprendre la preuve d'appareil | [`DEVICE_TRUST_PROTOCOL_V1.md`](../security/DEVICE_TRUST_PROTOCOL_V1.md) |
| sélectionner la prochaine tâche | [`ROADMAP.md`](../roadmap/ROADMAP.md) |

## Règle de maintenance

Une modification de route, événement, table, clé, format E2EE ou ordre de vérification doit mettre à jour cette matrice et le document spécialisé dans le même changement. Une référence « observée » ne devient une garantie qu'après tests et preuve attachés à la tâche correspondante.
