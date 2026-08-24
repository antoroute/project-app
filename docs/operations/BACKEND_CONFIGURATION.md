# Configuration des services backend

Statut : contrat opérationnel initial (`TC-101`)
Dernière mise à jour : 2026-08-24

Les services Auth et Messaging valident toute leur configuration avant de créer le serveur Fastify ou d'écouter sur le réseau. Les valeurs réelles restent dans le mécanisme de secrets de chaque environnement et ne doivent jamais être affichées, copiées dans Git ou placées dans une commande susceptible d'être journalisée.

## Variables

| Variable | Classe | Obligatoire | Validation |
|---|---|---:|---|
| `NODE_ENV` | opérationnelle | oui | `development`, `test`, `staging` ou `production` |
| `JWT_SECRET` | secret serveur | oui | au moins 32 caractères, sans espace périphérique ni placeholder connu |
| `APP_SECRET` | secret partagé transitoire | oui jusqu'à `TC-109` | distinct de `JWT_SECRET`, mêmes contrôles minimaux |
| `DATABASE_URL` | secret serveur | oui | URL `postgres://` ou `postgresql://` avec hôte, base, utilisateur et mot de passe |
| `PORT` | opérationnelle | non | entier de 1 à 65535 ; défaut interne 3000 pour Auth et 3001 pour Messaging |

`APP_SECRET` ne prouve pas qu'une requête provient de l'application officielle : toute valeur embarquée dans un client public est extractible. Son maintien évite seulement de casser le prototype avant sa suppression complète dans `TC-109`.

## Comportement d'échec

- Une variable obligatoire absente, vide ou invalide arrête le processus avec un code non nul avant l'écoute réseau.
- Le message d'erreur nomme seulement la variable et la règle violée ; il ne reproduit jamais sa valeur.
- Aucune configuration de développement implicite n'existe. Un développeur utilise exclusivement des valeurs synthétiques explicitement injectées.
- `JWT_SECRET` et `APP_SECRET` doivent être différents pendant leur coexistence.

## Staging

Compose exige les variables `TC_DB_NAME`, `TC_DB_USER`, `TC_DB_PASSWORD`, `TC_JWT_SECRET` et `TC_APP_SECRET`, puis construit `DATABASE_URL` dans l'environnement du conteneur. Le fichier privé reste `/opt/trust-circle-staging/shared/staging.env`, mode `0600`.

La configuration est vérifiée sans résolution visible :

```bash
docker compose \
  --project-name trust-circle-staging \
  --env-file /opt/trust-circle-staging/shared/staging.env \
  -f deploy/staging/compose.yml config --quiet
```

Ne jamais exécuter la même commande sans `--quiet` dans une sortie partagée.

## Rotation et rollback

Une rotation future doit coordonner tous les consommateurs, reconstruire les connexions et invalider les jetons lorsque la clé JWT change. Le rollback applicatif revient à l'image précédemment validée ; il ne doit jamais réintroduire une valeur par défaut. Un échec dû à une configuration manquante se corrige dans le mécanisme de secrets de l'environnement, après vérification du nom de variable, sans révéler sa valeur.
