# Environnements

Statut : politique cible
Dernière mise à jour : 2026-08-23

| Environnement | Usage | Données | Accès |
|---|---|---|---|
| Local | développement d'un composant | synthétiques uniquement | poste développeur |
| Test CI | tests automatisés éphémères | fixtures générées | pipeline isolé |
| Staging | intégration, migrations, restauration, bêta interne | synthétiques/anonymisées | accès restreint |
| Production | utilisateurs réels | données personnelles réelles | moindre privilège, actions approuvées |

## Isolation obligatoire

- Base, volumes, domaines, clés JWT, identifiants OAuth/push, certificats et comptes de service distincts.
- Aucun secret de production copié en local, staging, ticket, dépôt ou prompt.
- Aucune restauration de production en staging sans procédure d'anonymisation approuvée ; préférer des données synthétiques.
- Les noms de variables peuvent être documentés, jamais leurs valeurs.

## Capacité Docker disponible

Le propriétaire autorise l'utilisation de LXC106 pour les tests backend. Le LXC reste partagé avec d'autres services. Les anciennes stacks Trust Circle ont été supprimées et les tests sont dirigés vers `trust-circle-staging`, décrite dans `STAGING_INVENTORY.md`.

Le staging est actuellement accessible uniquement depuis le LXC via `127.0.0.1:18080`. Cette restriction est intentionnelle tant que les vulnérabilités Phase 1 ne sont pas fermées. Aucun test ne doit réutiliser les anciens domaines publics.

## Configuration

Classer chaque paramètre :

- Public client : URL d'API, nom d'environnement, version minimale. Ces valeurs peuvent être injectées au build sans `.env` secret embarqué.
- Secret serveur : signature JWT, mot de passe DB, clés SMTP/push, accès sauvegarde. Stockage dans un gestionnaire ou mécanisme de secrets de la plateforme.
- Opérationnel non secret : ports internes, noms de services, politiques de rétention.

L'application doit indiquer clairement l'environnement dans les builds non production. Un artefact production doit refuser une URL de staging et inversement.

## Promotion

Le même commit et, côté serveur, les mêmes digests d'images validés en staging sont promus en production. Les images ne sont pas reconstruites entre les deux. Une promotion conserve : version, commit, digest, migrations, date, opérateur, résultat des smoke tests et rollback.
