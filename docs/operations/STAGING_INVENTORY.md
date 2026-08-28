# Inventaire du staging backend

Statut : opérationnel, accès local au LXC uniquement
Dernier déploiement : 2026-08-28 (`TC-106`, lot D)
Environnement : LXC106, stack Compose `trust-circle-staging`

## Résumé

Le staging backend est une installation neuve et isolée des anciennes ressources supprimées. Il est destiné aux builds, smoke tests et futurs tests d'intégration automatisés. Il n'est pas un environnement de production et n'est pas exposé publiquement.

## Release

| Élément | Valeur assainie |
|---|---|
| Commit source | `9214b0a342cbcfccde4c6ed4fab04ec115d5311b` |
| Release | `/opt/trust-circle-staging/releases/9214b0a342cbcfccde4c6ed4fab04ec115d5311b` |
| Pointeur actif | `/opt/trust-circle-staging/current` |
| Fichier de secrets | `/opt/trust-circle-staging/shared/staging.env`, mode `0600` |
| Source Compose | `deploy/staging/compose.yml` |
| Projet Compose | `trust-circle-staging` |

Le fichier de secrets n'est pas versionné et ses valeurs n'ont pas été affichées pendant le déploiement.

## Services

| Service | Image | Preuve | État final |
|---|---|---|---|
| Auth | `trust-circle-staging-auth:staging-9214b0a342cb` | image ID `812a6a4385c5`, label revision complet | sain, 0 redémarrage |
| Messaging | `trust-circle-staging-messaging:staging-9214b0a342cb` | image ID `080e5ba89050`, label revision complet | sain, 0 redémarrage |
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
- 17 tables publiques observées ; `user_groups.role` reste contraint à `admin` ou `member`, et le propriétaire reste dérivé de `groups.creator_id`.
- Données uniquement synthétiques, créées par les smoke tests.
- Cinq migrations SQL réversibles sont conservées dans `infrastructure/postgres/migrations/` et appliquées manuellement pour `TC-104` à `TC-106`. Les trois dernières ajoutent le registre/preuve, les challenges d'approbation, puis la liaison signée et l'historique versionné des clés de cercle. Le choix et l'automatisation d'un véritable outil de migration restent suivis par `TC-201`.

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

Le redéploiement `TC-104` du 2026-08-25 a ensuite validé :

1. montée et descente de `20260825_001_group_member_role` dans un schéma isolé, avec conservation des appartenances et rejet d'un rôle invalide ;
2. sauvegarde PostgreSQL préalable vérifiée `pre-tc104-20260825T110719Z.dump`, conservée en mode `0600` dans le répertoire privé de sauvegardes du staging ;
3. application de la migration réelle et présence d'une unique colonne et contrainte de rôle, sans ligne invalide ;
4. build et déploiement des images Auth/Messaging depuis `f0e1baa7db2cd9c0e0cfd1104f477af25eec5b9f`, avec labels de révision correspondants ;
5. healthchecks des quatre services, zéro redémarrage des services applicatifs et aucun log Messaging de niveau erreur observé dans la fenêtre post-déploiement ;
6. deux smoke tests complets, dont le second avec trois comptes synthétiques : refus d'accès à l'annuaire hors cercle, création de conversation interdite sans écriture, décision d'adhésion par propriétaire puis administrateur, refus au membre simple et au non-propriétaire, vote neutralisé et poignée de main Socket.IO réussie.

La configuration précédente est conservée en mode `0600` sous `staging.env.before-f0e1baa7db2c`. La release `8ebeaa30f243a010d22070b8de20d969adedba89` reste disponible pour rollback applicatif ; la migration descendante a été exercée isolément avant le déploiement.

Le redéploiement `TC-105` du 2026-08-25 a ensuite validé :

1. montée et descente de `20260825_002_unique_pending_join_request` dans un schéma isolé, avec rejet du second doublon `pending` en montée et insertion de contrôle possible après descente ;
2. absence de doublon préalable puis sauvegarde PostgreSQL vérifiée `pre-tc105-20260825T123518Z.dump`, conservée en mode `0600` dans le répertoire privé de sauvegardes ;
3. application réelle de l'index partiel, sans suppression ni réécriture de donnée ;
4. build et déploiement des images Auth/Messaging depuis `abf6b51abf2967b7ddd0d43020690b0fc4872e8c`, avec labels de révision correspondants ;
5. healthchecks des quatre services, zéro redémarrage et aucun log de niveau erreur observé dans les quatre services après déploiement ;
6. smoke test complet réussi en 2 secondes : conversation, accusé de lecture et message réels, double demande concurrente donnant `201/409`, double décision donnant `200/403`, course publication/révocation terminant avec la clé `revoked`, puis refus de republier et d'envoyer depuis cet appareil ;
7. cohérence SQL finale : aucun cercle sans appartenance créateur, aucune conversation sans participant créateur et aucune demande acceptée sans appartenance ou clé d'appareil.

La configuration précédente est conservée en mode `0600` sous `staging.env.before-abf6b51abf29`. La release `f0e1baa7db2cd9c0e0cfd1104f477af25eec5b9f` reste disponible pour rollback applicatif ; l'application précédente est compatible avec l'index et la migration descendante a été exercée isolément.

Le redéploiement du lot B de `TC-106` du 2026-08-25 a ensuite validé :

1. sauvegarde PostgreSQL préalable vérifiée `pre-tc106-20260825T140433Z.dump`, mode `0600`, 32 389 octets et SHA-256 `dd5297a507ddbce9e02cddff305eafbd2a7a53ab336ca9d19188bd24d5dbb01c` ;
2. restauration de cette sauvegarde dans une base isolée, montée de `20260825_003_account_device_trust` avec trois tables/trois index, descente complète, conservation de la baseline puis suppression de la base isolée ;
3. migration additive de la base réelle sans réécriture des données existantes, puis build et déploiement du commit final `6450722344286341da0f9826dc080c35b6dc7f2d` ;
4. détection par le premier smoke réel d'une comparaison PostgreSQL ambiguë `uuid/text`, correction avec casts explicites, nouveau commit immuable et redéploiement sans recréer PostgreSQL ;
5. healthchecks des quatre services, zéro redémarrage et aucun log Auth/Messaging de niveau erreur dans la fenêtre suivant le déploiement final ;
6. smoke test historique complet, puis parcours réel de confiance : réauthentification, grant court, preuve Ed25519, rejet du rejeu, premier appareil `active`, second `pending`, refus d'un bootstrap avec access token seul et registre limité au sujet ;
7. cohérence SQL finale : zéro clé, transcription ou nonce de taille invalide, zéro transition d'état incohérente, zéro compte avec plusieurs appareils actifs et aucune base de test résiduelle.

Les configurations antérieures sont conservées en mode `0600` sous
`staging.env.before-060a293205aa` et `staging.env.before-645072234428`. La
release `abf6b51abf2967b7ddd0d43020690b0fc4872e8c` reste disponible pour
rollback applicatif et ne dépend d'aucune table ajoutée ; la migration
descendante a été exercée sur la restauration isolée avant la migration réelle.

Le redéploiement du lot C de `TC-106` du 2026-08-25 a ensuite validé :

1. sauvegarde PostgreSQL préalable vérifiée
   `pre-tc106-lotc-20260825T193057Z.dump`, mode `0600`, 46 785 octets et
   SHA-256 `524b1b463d77d5bba99e884fce7369f067fbacbbae7f911d1185f07f3adc3e89` ;
2. restauration dans `tc106_lotc_migration_test`, montée de
   `device_approval_challenges` avec une table, deux index et quatorze
   contraintes, descente complète, conservation de la baseline et suppression
   de la base isolée ;
3. migration additive de la base réelle, puis build et déploiement du commit
   `0a6e7a0062c0c8fd8ca57f2dd78a15989a4b27a4`, avec labels de révision
   correspondants ;
4. quatre healthchecks sains, zéro redémarrage et zéro ligne `error|fatal`
   Auth/Messaging dans la fenêtre post-déploiement ;
5. smoke historique complet puis parcours réel : bootstrap, preuve Ed25519,
   appareil suivant `pending`, approbation signée, rejeu refusé, troisième
   appareil refusé par signature et registre final `active,active,revoked` ;
6. cohérence SQL finale : zéro taille/état incohérent, zéro challenge ouvert
   visant une cible non `pending`, zéro résultat hors vocabulaire et aucune base
   de migration résiduelle.

La configuration précédente est conservée en mode `0600` sous
`staging.env.before-0a6e7a0062c0`. La release
`6450722344286341da0f9826dc080c35b6dc7f2d` reste disponible pour rollback
applicatif et ignore sans erreur la table additive du lot C.

Le redéploiement du lot D de `TC-106` du 2026-08-28 a ensuite validé :

1. sauvegarde PostgreSQL préalable
   `pre-tc106-lotd-20260828T200545Z.dump`, mode `0600`, 55 653 octets et
   SHA-256 `037f05683ada6b5aec700463ecbc456233e0d0f76a6afc0d68918963f6c95a9b` ;
2. restauration dans `tc106_lotd_migration_test`, montée avec une table
   d'historique, quatre colonnes et cinq contraintes nommées, puis descente
   vers la baseline exacte `29 utilisateurs / 11 clés / 2 challenges /
   4 messages` et suppression de la base isolée ;
3. détection avant migration réelle de deux défauts de rollback — conservation
   de l'état historique et ordre de suppression des contraintes — corrigés et
   rejoués avec succès sur la restauration ;
4. courte fenêtre d'arrêt Auth/Messaging/Gateway, migration transactionnelle de
   la base réelle, conversion de sept anciennes clés en `legacy`, aucune clé
   `active` incomplète, puis déploiement de la release finale
   `9214b0a342cbcfccde4c6ed4fab04ec115d5311b` ;
5. correction révélée par le smoke d'un écart contractuel : la création de
   conversation renvoie désormais `201 Created`, protégée par un test backend ;
6. parcours final réussi : bearer seul refusé, preuve d'accès signée,
   isolation `pending`, approbation/refus, publications signées, rejeu
   idempotent, rotation et historique, refus d'une version obsolète, course
   publication/révocation globale, blocage immédiat et anciens messages encore
   accessibles ;
7. quatre healthchecks sains, labels correspondant au commit final, zéro
   redémarrage et zéro ligne Auth/Messaging `error|fatal` dans la fenêtre du
   dernier déploiement ;
8. neuf contrôles SQL finaux à zéro : tailles/états invalides des appareils et
   challenges, clés courantes/historiques invalides, clé active d'un appareil
   révoqué, historique non monotone, version destinataire invalide et base de
   migration résiduelle.

Les configurations précédentes sont conservées en mode `0600` sous
`staging.env.before-7d0d3afdbdfa`, `staging.env.before-2c79c0cbb79c` et
`staging.env.before-9214b0a342cb`. Les releases
`7d0d3afdbdfaf458146e1e63df3f69520662bb20` et
`2c79c0cbb79c46cd808cec3759766c8445bda69d` restent disponibles pour
rollback applicatif ; la descente SQL a été exercée uniquement sur la
restauration isolée.

## Limites assumées

- Pas de domaine ni TLS : accès volontairement local jusqu'à la revue de fermeture de Phase 1.
- Pas encore de build Flutter ciblant le staging.
- Pas encore d'outil de migrations ni de restauration complète du volume principal ; les migrations `TC-104` à `TC-106` et leurs rollbacks ont été exercés dans un environnement PostgreSQL isolé, mais appliqués manuellement au staging.
- Les principaux scénarios d'autorisation croisée cercle/conversation/clé de `TC-104` sont couverts ; l'élargissement de la suite d'intégration PostgreSQL et des tests négatifs reste suivi par `TC-111`.
- Images backend locales non publiées dans un registre ; l'image ID et les labels assurent la traçabilité locale, pas une provenance distante.
- Le LXC reste partagé et privilégié.

## Commandes de référence

Le déploiement, l'arrêt conservant les données et les smoke tests sont décrits dans `deploy/staging/README.md`. Ne jamais afficher la configuration Compose résolue ni le fichier d'environnement.
