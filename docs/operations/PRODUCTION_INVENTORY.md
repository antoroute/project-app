# Inventaire assaini de l'environnement Docker

Statut : inventaire en lecture seule terminé, écarts ouverts
Date d'observation : 2026-08-23
Périmètre : LXC Docker partagé, stacks historiques `app` et `infra`
Guide opérateur privé : `/root/homelab/documentation/guides-services/05-docker-portainer.md`

Ce document ne contient volontairement ni adresse interne, valeur de variable, utilisateur de base, donnée applicative ou détail d'accès. Les commandes ont été exécutées depuis l'hôte Proxmox avec `pct exec 106` et des sélections Docker qui excluent les valeurs d'environnement.

> État historique : après cet inventaire, le propriétaire a abandonné les données et autorisé la purge. Les ressources `app`/`infra` décrites ici ont été supprimées le 2026-08-23. Le document conserve la preuve de l'état trouvé avant suppression.

## Conclusion opérationnelle

Les artefacts Trust Circle sont présents, mais le backend n'est pas actuellement en service : les stacks `app` et `infra` sont arrêtées et les domaines publics observés ne répondent pas. L'environnement ne doit donc pas être considéré comme une production active ni comme une cible de tests avant sauvegarde et isolation.

Les services auth/messaging ont fonctionné du 2 au 12 août 2026, alors que PostgreSQL et Redis sont arrêtés depuis le 18 décembre 2025. Leurs derniers healthchecks HTTP réussissaient, car ils vérifient seulement le processus `/health` et pas les dépendances. Cet état peut présenter un service « sain » alors que les parcours utilisant la base sont indisponibles.

## Hôte et moteur Docker

| Élément | État observé |
|---|---|
| Type | LXC Docker partagé avec d'autres applications |
| OS | Debian 12, amd64 |
| Ressources | 4 vCPU, 10 Gio RAM, 2 Gio swap, rootfs 80 Gio |
| Utilisation observée | 39 % du rootfs, 6,3 Gio de RAM disponible |
| Horloge | Europe/Paris, synchronisée |
| Services systemd défaillants | aucun au moment de l'inventaire |
| Docker | 28.4.0, API 1.51, `overlay2` |
| Docker Compose | 2.31.0 |
| Live restore Docker | désactivé |
| Charge mutualisée | 39 conteneurs connus, dont 19 en cours lors du relevé |
| Isolation LXC | conteneur privilégié constaté par l'UID map |
| Pare-feu CT Proxmox | aucune option/règle propre au CT détectée |

Le moteur est partagé et le LXC privilégié. Une erreur Docker ou une saturation Trust Circle peut donc affecter d'autres services, et inversement. La protection réseau amont n'a pas été auditée dans cette tâche.

## Stacks Trust Circle

### État des conteneurs

| Service | Image/référence | Image ID abrégé | Création image | Dernier état |
|---|---|---|---|---|
| Nginx | `app-nginx:latest` locale | `db4a05a32c1a` | 2025-11-24 | arrêté normalement le 2026-08-12 |
| Auth | `app-auth:latest` locale | `b9ad238c3a91` | 2025-12-02 | arrêté code 137 le 2026-08-12, pas d'OOM |
| Messaging | `app-messaging:latest` locale | `52e6bfc711f0` | 2025-12-02 | arrêté code 137 le 2026-08-12, pas d'OOM |
| PostgreSQL | `infra-postgres:latest` locale | `80260133147c` | 2025-11-29 | arrêté normalement le 2025-12-18 |
| Redis | ancienne image `redis:7` | `07a03ad21d6a` | 2025-11-18 | arrêté normalement le 2025-12-18 |

Les arrêts auth/messaging suivent à environ dix secondes l'arrêt Nginx, leurs healthchecks passaient juste avant, et `OOMKilled=false`. Cela ressemble à un arrêt ordonné suivi d'un `SIGKILL` après timeout plutôt qu'à une panne mémoire ; l'événement Docker historique n'est plus disponible pour le prouver.

PostgreSQL/Redis n'ont aucune politique de redémarrage. Les services app utilisent `restart: always`, mais sont restés arrêtés après l'arrêt de la stack.

### Provenance

- Les images locales `app-*` et `infra-postgres` utilisent le tag mutable `latest`.
- Elles ne portent aucun digest de registre, label de commit, source ou version OCI.
- Les fichiers TypeScript, Compose, Nginx, `init.sql` et `redis.conf` conservés par Portainer ont des hashes SHA-256 identiques aux fichiers du dépôt local audité.
- La dernière modification backend Git avant la création des images est `83387d3` du 2025-12-02 ; l'image a été créée environ deux minutes plus tard. C'est une corrélation, pas une preuve de provenance.
- Le commit local courant `1988bf6` ne modifie que le client Flutter après cette version backend.

Conclusion : la source Portainer correspond au backend local, mais l'artefact exécuté ne peut pas être relié cryptographiquement à un commit. La CI future doit produire labels OCI, SBOM et images par digest.

## Configuration sans valeurs

Le fichier d'environnement Portainer existe avec permissions `0600`, propriétaire root. Seuls les noms suivants ont été relevés et leur présence non vide confirmée :

- Auth : `APP_SECRET`, `DATABASE_URL`, `JWT_SECRET`, `PORT`.
- Messaging : `APP_SECRET`, `DATABASE_URL`, `JWT_SECRET`, `PORT`, `REDIS_URL`, `REDIS_PASSWORD`.
- PostgreSQL : `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`.

Auth et messaging ciblent logiquement `postgres:5432`; messaging cible aussi `redis:6379`. Aucune valeur n'a été extraite. Le stockage actuel reste basé sur variables d'environnement, pas sur des secrets Docker dédiés.

## Réseaux et exposition

- `app_backend_net` relie Nginx aux services applicatifs.
- `db_net` est un bridge externe partagé entre les deux projets Compose.
- Les deux réseaux ont `internal=false`; aucun conteneur n'y était attaché puisque les stacks sont arrêtées.
- Auth, messaging, PostgreSQL et Redis ne publient pas directement de port hôte.
- Nginx déclare les ports hôte 80 et 443, mais sa configuration ne contient qu'un listener HTTP 80.
- Aucun port 80, 443, 3000, 3001, 5432 ou 6379 n'écoutait sur le LXC lors du relevé.

La configuration Nginx route les domaines publics historiques vers auth (`/auth/`) et messaging (`/api/`, `/socket`). Aucun certificat n'est présent dans le bind mount Certbot et aucune configuration TLS 443 n'existe dans cette stack. Les requêtes HTTP/HTTPS externes vers les deux domaines ont expiré. L'existence d'un proxy TLS amont pour ces domaines n'est pas documentée ni démontrée.

## Données et schéma

| Volume | État |
|---|---|
| `infra_pgdata` | volume local, environ 46 Mio, cluster PostgreSQL majeur 15 |
| `infra_redisdata` | volume local, environ 8 Kio |

Le répertoire PostgreSQL contient un cluster initialisé ; son dernier `pg_control` observé date du 18 décembre 2025. Le volume Docker est aujourd'hui étiqueté comme créé le 1er août 2026 alors que ses fichiers sont plus anciens : sa filiation doit être clarifiée avant toute écriture.

L'image PostgreSQL contient PostgreSQL 15.15. Le script `init.sql` distant correspond au dépôt et aucun outil/historique de migration n'est présent. Comme la base est arrêtée, le schéma et les volumes de lignes réellement stockés n'ont volontairement pas été interrogés. Ils restent inconnus jusqu'à une restauration isolée ou un démarrage explicitement autorisé après sauvegarde.

Les volumes Docker sont sur le rootfs du LXC, pas sur un montage NFS séparé.

## Sauvegardes

- Un job Proxmox mensuel couvre tous les invités et conserve une génération locale.
- Une archive LXC106 datée du 9 août 2026 existe sur `backup-export` (environ 8,1 Gio).
- La documentation homelab indique que l'archive et sa somme ont été vérifiées lors du premier cycle.
- Le stockage de transit reste sur le même serveur ; une copie hors hôte est manuelle et n'a pas été prouvée pour cette génération.
- Aucun `pg_dump`, timer, cron ou runbook Trust Circle spécifique n'a été trouvé.
- Aucune restauration de LXC ou de PostgreSQL Trust Circle n'est documentée comme testée.

Le snapshot LXC protège physiquement le volume Docker, mais ne remplace pas une sauvegarde PostgreSQL logique/physique cohérente ni un test de restauration applicatif. `TC-003` reste donc bloquant.

## Durcissement et observabilité

- Les cinq conteneurs inspectés utilisent le pilote de logs `journald`; le guide homelab indique qu'Alloy transmet les logs Docker à Loki.
- Aucune preuve de redaction applicative des contenus, jetons ou identifiants n'a été établie.
- Aucun conteneur inspecté ne configure utilisateur non-root, rootfs en lecture seule, `no-new-privileges`, réduction de capabilities, limite mémoire/CPU/PID.
- Les conteneurs ne sont pas privilégiés individuellement, mais ils s'exécutent dans un LXC privilégié.
- Les images ont des healthchecks de processus pour auth/messaging. Il manque des readiness checks sur PostgreSQL/Redis et une santé bout en bout.
- L'état de surveillance publique Gatus pour les domaines Trust Circle n'a pas été trouvé dans la documentation consultée.

## Écarts prioritaires

| Niveau | Écart | Suite |
|---|---|---|
| P0 | L'instance n'est pas active malgré l'hypothèse initiale | ne pas la redémarrer avant sauvegarde et décision d'environnement |
| P0 | PostgreSQL/Redis étaient arrêtés pendant le dernier fonctionnement app | readiness réelle, dépendances et ordre de démarrage à corriger |
| P0 | Pas de sauvegarde PostgreSQL/restauration prouvée | TC-003 |
| P0 | Filiation du volume `pgdata` non expliquée | préserver puis examiner dans la restauration isolée |
| P1 | Pas de provenance/digest des images | TC-209 |
| P1 | Pas de migrations versionnées | TC-201/TC-202 |
| P1 | TLS absent dans la stack et proxy amont inconnu | TC-004/TC-207 |
| P1 | LXC privilégié et hôte partagé sans règles CT propres | évaluation d'isolation dans TC-004/TC-204 |
| P1 | Secrets injectés par variables et faux `APP_SECRET` client | TC-101/TC-109 |
| P1 | Aucun quota/limite/durcissement conteneur | TC-204 |
| P1 | Logs centralisés sans preuve de redaction | TC-206 |

## Décision de test

LXC106 peut servir de capacité Docker pour les futurs tests backend avec l'autorisation du propriétaire. La cible de test doit être une stack staging séparée créée par `TC-004`, avec projet, domaines/ports, réseaux, volumes, base, secrets et fournisseurs de notifications distincts.

Les stacks historiques `app` et `infra` ne doivent pas recevoir de tests mutatifs. Avant tout redémarrage ou remplacement : clôturer `TC-003`, inspecter la restauration isolée, puis décider si elles sont à archiver ou à migrer.

## Traçabilité de l'inventaire

Toutes les commandes de service étaient des lectures (`status`, `inspect`, `compose config`, hashes, métadonnées, réseau, stockage, certificats et sauvegardes). Une commande `compose config` a brièvement créé deux fichiers de travail sous `/tmp` pour filtrer la sortie ; ils ont été supprimés immédiatement et leur absence vérifiée. Aucun conteneur, réseau, volume, donnée, secret, règle ou service n'a été démarré, arrêté ou modifié.

## Inconnues restantes

- Schéma et données effectivement présents dans le cluster PostgreSQL.
- Cause humaine exacte et ticket/commande de l'arrêt du 12 août.
- Existence d'une copie récente hors hôte de l'archive LXC.
- Topologie du proxy/DNS amont et propriétaire des certificats des domaines historiques.
- Durées/règles de rétention journald/Loki et redaction réelle.
- Stratégie de suppression ou conservation de cette instance historique.

Ces inconnues n'empêchent pas de clore l'inventaire en lecture seule ; elles deviennent des entrées de `TC-003`, `TC-004` et des tâches de durcissement.
