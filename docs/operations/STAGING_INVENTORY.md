# Inventaire du staging backend

Statut : opérationnel, accès local au LXC uniquement
Dernier déploiement : 2026-08-24 (`TC-103`)
Environnement : LXC106, stack Compose `trust-circle-staging`

## Résumé

Le staging backend est une installation neuve et isolée des anciennes ressources supprimées. Il est destiné aux builds, smoke tests et futurs tests d'intégration automatisés. Il n'est pas un environnement de production et n'est pas exposé publiquement.

## Release

| Élément | Valeur assainie |
|---|---|
| Commit source | `8ebeaa30f243a010d22070b8de20d969adedba89` |
| Release | `/opt/trust-circle-staging/releases/8ebeaa30f243a010d22070b8de20d969adedba89` |
| Pointeur actif | `/opt/trust-circle-staging/current` |
| Fichier de secrets | `/opt/trust-circle-staging/shared/staging.env`, mode `0600` |
| Source Compose | `deploy/staging/compose.yml` |
| Projet Compose | `trust-circle-staging` |

Le fichier de secrets n'est pas versionné et ses valeurs n'ont pas été affichées pendant le déploiement.

## Services

| Service | Image | Preuve | État final |
|---|---|---|---|
| Auth | `trust-circle-staging-auth:staging-8ebeaa30f243` | image ID `84b79f800a6b`, label revision complet | sain |
| Messaging | `trust-circle-staging-messaging:staging-8ebeaa30f243` | image ID `9859e2d897d7`, label revision complet | sain |
| PostgreSQL | `postgres:16-alpine` résolue par digest | digest conservé dans le fichier privé | sain |
| Gateway | `nginx:stable-alpine` résolue par digest | digest conservé dans le fichier privé | sain |

Les références tierces exactes observées au déploiement sont :

- PostgreSQL : `postgres@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685` ;
- Nginx : `nginx@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46`.

## Isolation

- Gateway : `127.0.0.1:18080` sur le LXC uniquement.
- Auth et messaging : aucune publication de port hôte.
- PostgreSQL : aucune publication de port hôte, réseau interne `trust-circle-staging-data`.
- Réseaux : `trust-circle-staging-edge` et `trust-circle-staging-data`.
- Volume : `trust-circle-staging-postgres-data`.
- Aucun domaine, certificat, volume, réseau ou secret historique réutilisé.
- Aucun e-mail ou fournisseur push configuré.
- Redis absent car non utilisé par le code.

Les tests backend sont exécutés via `pct exec 106` et la gateway loopback. Toute exposition LAN/Internet exige une décision séparée après la fermeture des vulnérabilités Phase 1.

## Durcissement appliqué

Auth, messaging et gateway utilisent : utilisateur non-root, rootfs en lecture seule, `no-new-privileges`, toutes les capabilities supprimées, limites CPU/mémoire/PID, init, délai d'arrêt et journald avec tag staging.

PostgreSQL utilise un volume inscriptible, des limites de ressources, un healthcheck et un réseau interne. Son image officielle n'est pas encore durcie avec un utilisateur/jeu de capabilities Compose spécifique ; ce point appartient à `TC-204`.

## Schéma et données

- Base PostgreSQL 16 neuve.
- `infrastructure/postgres/init.sql` monté en lecture seule pour la première initialisation.
- 12 tables publiques observées.
- Données uniquement synthétiques, créées par les smoke tests.
- Aucun système de migration versionnée : blocage suivi par `TC-201`.

## Validations exécutées

1. Validation Compose avec sortie silencieuse.
2. Build des deux images backend depuis le commit enregistré.
3. Healthchecks PostgreSQL, auth, messaging et gateway.
4. Inscription et connexion d'un compte `example.invalid` synthétique.
5. Appel authentifié `/auth/me`.
6. Rejet HTTP 403 d'un mauvais `x-app-secret`.
7. Création puis lecture d'un cercle synthétique.
8. Handshake Socket.IO par polling.
9. `docker compose down` puis `up` sans suppression de volume.
10. Vérification que les comptages utilisateurs/cercles sont identiques avant/après reprise.
11. Nouvelle exécution complète des smoke tests après reprise.

Tous ces tests ont réussi le 2026-08-23.

Le redéploiement `TC-101` du 2026-08-24 a en plus validé :

1. build des images Auth et Messaging avec la configuration centralisée ;
2. arrêt avec code `1` de chaque image lancée sans configuration critique ;
3. conservation du fichier privé en mode `0600`, sans affichage de valeur ;
4. healthchecks des quatre services et smoke test fonctionnel complet après remplacement des conteneurs ;
5. traçabilité du commit dans les labels des deux images.

La release précédente et un instantané privé de la configuration antérieure au changement des métadonnées de release sont conservés sur le LXC pour rollback. Les secrets applicatifs eux-mêmes n'ont pas été changés.

Le redéploiement `TC-102` du 2026-08-24 a ensuite validé :

1. migration du nom de la clé access et génération d'une clé refresh séparée, sans afficher de valeur ;
2. présence des noms `JWT_ACCESS_SECRET` et `JWT_REFRESH_SECRET` dans Auth, et de la seule clé access dans Messaging ;
3. contrat strict HS256/issuer/audience/type/version/temps par 26 tests automatisés ;
4. refus REST du refresh token dans Auth et Messaging, refus access sur refresh/logout, révocation effective et refus Socket.IO couvert par test automatisé ;
5. refus HTTP 401 d'un JWT au format historique malgré la conservation de la matière de clé access ;
6. healthchecks des quatre services et smoke test complet après redéploiement.

Le durcissement asymétrique final de `TC-102` a en plus validé :

1. génération sans affichage d'une paire Ed25519 dédiée au staging ;
2. présence de la clé privée, de la clé publique et du secret refresh dans Auth, contre la seule clé publique dans Messaging ;
3. impossibilité effective de signer un access token depuis le conteneur Messaging ;
4. coût moyen dans le conteneur Auth de 0,0773 ms par signature et 0,1499 ms par vérification sur 2 000 opérations, sous le budget de 2 ms ;
5. healthchecks des quatre services et smoke test strict access/refresh après remplacement des conteneurs.

La paire access a été renouvelée, ce qui invalide volontairement les access tokens antérieurs. La configuration privée immédiatement antérieure est conservée en mode `0600` sous `staging.env.before-e7be1b027923`, et les releases précédentes restent disponibles pour rollback du staging.

Le redéploiement `TC-103` du 2026-08-24 a enfin validé :

1. build des images Auth et Messaging depuis le commit `8ebeaa30f243a010d22070b8de20d969adedba89` et traçabilité de cette révision dans leurs labels ;
2. healthchecks des quatre services ;
3. smoke test complet, incluant deux comptes synthétiques et le refus HTTP 403 d'une enveloppe dont le `sender.userId` ne correspond pas au token ;
4. conservation de la paire Ed25519 existante et de la séparation des secrets établie par `TC-102` ;
5. coût moyen de la dérivation typée de l'identité de 0,000125 ms sur 500 000 appels dans Messaging, sans réseau ni base.

La configuration immédiatement antérieure au changement de métadonnées est conservée en mode `0600` sous `staging.env.before-8ebeaa30f243`. La release `e7be1b027923a7868cca3145694e9bcc27217332` reste disponible pour rollback applicatif sans restauration de données.

## Limites assumées

- Pas de domaine ni TLS : accès volontairement local jusqu'à la revue de fermeture de Phase 1.
- Pas encore de build Flutter ciblant le staging.
- Pas de migrations ni preuve de restauration du nouveau volume.
- Le scénario d'usurpation d'identité est couvert, mais les tests d'autorisation croisée cercle/conversation/clé ne sont pas encore exhaustifs (`TC-104` et `TC-111`).
- Images backend locales non publiées dans un registre ; l'image ID et les labels assurent la traçabilité locale, pas une provenance distante.
- Le LXC reste partagé et privilégié.

## Commandes de référence

Le déploiement, l'arrêt conservant les données et les smoke tests sont décrits dans `deploy/staging/README.md`. Ne jamais afficher la configuration Compose résolue ni le fichier d'environnement.
