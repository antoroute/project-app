# Consignes de travail pour les assistants IA

Ce fichier s'applique à tout le dépôt. Il est destiné aux assistants qui participent au développement de Trust Circle avec le propriétaire du projet.

## Lecture obligatoire avant toute modification

Lire, dans cet ordre :

1. `docs/PROJECT_CONTEXT.md` ;
2. la fiche `docs/tasks/TC-xxx.md` concernée ;
3. `docs/security/SECURITY_INVARIANTS.md` pour toute modification applicative ;
4. les ADR et documents spécialisés liés à la tâche ;
5. le code et les tests réellement concernés.

En cas de contradiction, l'instruction explicite du propriétaire prévaut, puis la fiche de tâche, les ADR acceptés, les invariants de sécurité et enfin les autres documents. Signaler la contradiction au lieu de la masquer.

## Règles non négociables

- Ne jamais afficher, copier, versionner ou placer dans un prompt une valeur de secret, clé, jeton, mot de passe, contenu de `.env`, sauvegarde ou donnée personnelle réelle.
- Ne jamais modifier la production sans autorisation humaine explicite, cible vérifiée, sauvegarde exploitable et procédure de retour arrière.
- Ne jamais faire confiance à un identifiant d'utilisateur fourni par un client. L'identité vient exclusivement d'un jeton d'accès vérifié côté serveur.
- Ne jamais contourner une autorisation de cercle, conversation ou clé d'appareil pour « débloquer » une fonctionnalité.
- Ne jamais affaiblir le chiffrement, inventer un protocole ou revendiquer la sécurité de Signal/MLS sans décision d'architecture et preuves adaptées.
- Ne jamais notifier, afficher ou persister comme valide un message dont l'authenticité n'a pas été vérifiée.
- Toute évolution du schéma PostgreSQL passe par une migration versionnée avec stratégie de retour arrière.
- Préserver les modifications locales qui ne font pas partie de la tâche.

## Méthode d'exécution d'une tâche

1. Reformuler l'objectif et les critères d'acceptation de la fiche.
2. Vérifier l'état Git et inspecter les fichiers utiles.
3. Identifier les risques de sécurité, données, compatibilité et déploiement.
4. Écrire ou adapter les tests de régression avant ou avec le correctif.
5. Faire le changement minimal qui satisfait les critères.
6. Exécuter les validations proportionnées au risque.
7. Mettre à jour la fiche, les contrats ou la documentation si le comportement change.
8. Rendre compte des fichiers modifiés, validations exécutées, limites et prochaine étape.

Une tâche ne doit pas être déclarée terminée si un critère d'acceptation n'est pas vérifié. Une validation non exécutable doit être signalée explicitement.

## Commandes de validation actuelles

Backend, dans chacun des dossiers `backend/auth` et `backend/messaging` :

```bash
npm ci
npm run build
```

Il n'existe pas encore de scripts de lint ou de test backend : leur absence est un risque connu, pas une validation réussie.

Application Flutter, dans `frontend-mobile/flutter_message_app` :

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

Les builds iOS/macOS doivent être validés sur macOS avec Xcode. Les builds Windows doivent être validés sur Windows. Ne pas créer une fausse valeur `.env` pour faire passer un build : la configuration publique et les secrets doivent d'abord être séparés.

Documentation :

```bash
git diff --check
```

## Production et infrastructure

- L'état réel de la VM ne peut pas être déduit du dépôt. Utiliser `TC-002` pour établir un inventaire assaini.
- L'inventaire courant est `docs/operations/PRODUCTION_INVENTORY.md`. Le propriétaire autorise LXC106 pour les tests backend, uniquement via une stack staging isolée tant qu'une nouvelle autorisation n'indique pas explicitement une autre cible.
- Ne collecter que les noms de variables d'environnement, jamais leurs valeurs.
- Aucun développement courant directement en production. Utiliser l'environnement de staging défini dans `docs/operations/ENVIRONMENTS.md`.
- Avant une action risquée : préciser la cible, l'impact, la sauvegarde, la commande, la vérification et le rollback ; attendre l'autorisation humaine.

## Modèle de livraison

Chaque compte rendu de tâche doit contenir : résultat, fichiers modifiés, validations exécutées, validations non exécutées avec leur motif, risque résiduel et identifiant de la prochaine tâche recommandée.
