# Déploiement staging

Cette stack remplace les anciens projets génériques `app` et `infra`. Son nom Docker Compose est toujours `trust-circle-staging`.

## Propriétés

- PostgreSQL dédié et volume `trust-circle-staging-postgres-data`.
- Réseaux `trust-circle-staging-edge` et `trust-circle-staging-data`.
- Redis absent : aucun code backend actuel ne l'utilise.
- Auth/messaging non publiés sur l'hôte.
- Gateway liée uniquement à `127.0.0.1:18080` sur le LXC tant que TLS et les premières corrections P0 ne sont pas terminés.
- Secrets générés hors dépôt dans un fichier `0600`.
- Images backend étiquetées avec le commit et la version de staging.
- Images PostgreSQL/Nginx fournies par digest dans le fichier d'environnement privé.
- Configuration backend validée avant écoute selon `docs/operations/BACKEND_CONFIGURATION.md` ; aucun fallback de secret ou de connexion PostgreSQL.

## Déploiement sur LXC106

Le code source est copié dans un répertoire de release sous `/opt/trust-circle-staging/releases/<commit>`. Les secrets restent dans `/opt/trust-circle-staging/shared/staging.env`.

1. Tirer les tags officiels approuvés, puis relever leurs `RepoDigests`.
2. Créer le fichier privé une seule fois :

```bash
bash deploy/staging/generate-env.sh \
  /opt/trust-circle-staging/shared/staging.env \
  <FULL_COMMIT> staging-<SHORT_COMMIT> \
  postgres@sha256:<DIGEST> nginx@sha256:<DIGEST>
```

3. Valider sans afficher la configuration résolue :

```bash
docker compose \
  --project-name trust-circle-staging \
  --env-file /opt/trust-circle-staging/shared/staging.env \
  -f deploy/staging/compose.yml config --quiet
```

4. Construire et démarrer :

```bash
docker compose \
  --project-name trust-circle-staging \
  --env-file /opt/trust-circle-staging/shared/staging.env \
  -f deploy/staging/compose.yml up -d --build
```

5. Attendre les healthchecks puis exécuter :

```bash
bash deploy/staging/smoke-test.sh \
  /opt/trust-circle-staging/shared/staging.env
```

Ne jamais exécuter `docker compose config` sans `--quiet` dans une sortie partagée : la configuration résolue contient des secrets.

## Inspection sûre

```bash
docker compose --project-name trust-circle-staging \
  --env-file /opt/trust-circle-staging/shared/staging.env \
  -f deploy/staging/compose.yml ps
```

Pour documenter les variables, extraire uniquement leurs noms via `docker inspect` et `jq`; ne pas copier la sortie brute.

## Accès client

La première livraison est volontairement locale au LXC. L'ajout d'un domaine staging TLS, d'une restriction d'accès et d'une configuration Flutter dédiée reste requis avant un test sur appareil physique. Aucun client ne doit utiliser les domaines de production historiques.

## Destruction du staging

La suppression du volume PostgreSQL est irréversible. Elle exige une autorisation explicite distincte et une résolution exacte du projet :

```bash
docker compose --project-name trust-circle-staging \
  --env-file /opt/trust-circle-staging/shared/staging.env \
  -f deploy/staging/compose.yml down
```

La commande ci-dessus conserve volontairement le volume. Ne pas ajouter `--volumes` sans décision explicite sur les données de staging.
