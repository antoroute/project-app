# TC-101 — Faire échouer les services si une configuration critique manque

Statut : En cours
Priorité : P0 sécurité
Décision : mainteneur, avec revue sécurité
Dépendances : TC-004

## Objectif

Supprimer tous les fallbacks silencieux de configuration critique des services Auth et Messaging. Un processus doit refuser de démarrer avant d'écouter sur le réseau si un secret serveur, l'accès PostgreSQL ou l'environnement d'exécution est absent ou manifestement invalide.

## Périmètre

- `backend/auth` et `backend/messaging`.
- Variables obligatoires : `NODE_ENV`, `JWT_SECRET`, `DATABASE_URL` et, temporairement jusqu'à `TC-109`, `APP_SECRET`.
- Paramètre opérationnel : `PORT`, optionnel avec valeur interne connue, mais strictement validé s'il est fourni.
- Compose et procédures du staging `trust-circle-staging`.

## Hors périmètre

- Séparer access token et refresh token (`TC-102`).
- Retirer le secret partagé de l'application publique (`TC-109`).
- Séparer les comptes PostgreSQL par service (`TC-203`).
- Modifier la production ou ses secrets.

## Invariants affectés

- Invariant 4 : absence d'un secret ou paramètre cryptographique critique = échec du démarrage.
- Invariant 5 : aucun secret dans les journaux ou messages d'erreur.
- Invariant 26 : `APP_SECRET` ne pourra pas rester dans une application distribuée ; son exigence serveur est transitoire jusqu'à `TC-109`.

## Travail

1. Centraliser le chargement et la validation de configuration dans chaque service.
2. Supprimer les valeurs de repli de `JWT_SECRET`, `APP_SECRET` et `DATABASE_URL`.
3. Refuser valeurs vides, espaces parasites, secrets trop courts ou valeurs historiques connues.
4. Vérifier le schéma PostgreSQL de `DATABASE_URL` et la plage de `PORT` sans jamais journaliser les valeurs.
5. Injecter la configuration validée dans Fastify, PostgreSQL et Socket.IO au lieu de relire directement `process.env`.
6. Ajouter des tests automatisés de succès et d'échec, dont un lancement réel sans configuration.
7. Rebuilder et redéployer uniquement le staging autorisé avec ses secrets existants, puis exécuter les smoke tests assainis.

## Critères d'acceptation

- [ ] Aucun fallback de secret ou de connexion PostgreSQL ne subsiste dans les sources backend.
- [ ] Chaque service échoue avec un code non nul avant écoute si une variable critique manque ou est invalide.
- [ ] Les erreurs nomment le paramètre fautif sans afficher sa valeur.
- [ ] Les configurations valides de développement synthétique et de staging sont acceptées.
- [ ] Builds TypeScript et tests automatisés passent pour les deux services.
- [ ] Le staging redéployé reste sain et ses smoke tests passent sans exposer de secret.
- [ ] La liste des variables et le rollback sont documentés.

## Validation prévue

Dans chaque service :

```bash
npm ci
npm test
npm run build
```

Sur LXC106, uniquement via `trust-circle-staging` : rebuild des deux images au commit validé, contrôle des healthchecks et exécution de `deploy/staging/smoke-test.sh` avec le fichier privé existant.

## Rollback

Revenir aux images du commit staging précédent et conserver le fichier d'environnement privé existant. Ne jamais réintroduire les fallbacks : si une incompatibilité de configuration apparaît, corriger les noms/valeurs dans le mécanisme de secrets de l'environnement concerné.
