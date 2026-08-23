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

Le propriétaire autorise l'utilisation de LXC106 pour les tests backend. L'inventaire du 2026-08-23 montre toutefois que ce LXC est partagé avec d'autres services et que les anciennes stacks Trust Circle sont arrêtées. Les tests seront donc dirigés vers une stack staging distincte créée par `TC-004`, jamais vers les volumes/projets historiques `app` et `infra`.

## Configuration

Classer chaque paramètre :

- Public client : URL d'API, nom d'environnement, version minimale. Ces valeurs peuvent être injectées au build sans `.env` secret embarqué.
- Secret serveur : signature JWT, mot de passe DB, clés SMTP/push, accès sauvegarde. Stockage dans un gestionnaire ou mécanisme de secrets de la plateforme.
- Opérationnel non secret : ports internes, noms de services, politiques de rétention.

L'application doit indiquer clairement l'environnement dans les builds non production. Un artefact production doit refuser une URL de staging et inversement.

## Promotion

Le même commit et, côté serveur, les mêmes digests d'images validés en staging sont promus en production. Les images ne sont pas reconstruites entre les deux. Une promotion conserve : version, commit, digest, migrations, date, opérateur, résultat des smoke tests et rollback.
