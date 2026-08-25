# TC-104 — Centraliser la matrice ACL cercle, conversation et rôle

Statut : Terminée
Priorité : P0 sécurité
Décision : mainteneur, avec revue sécurité
Dépendances : TC-103

## Contexte et problème

Les routes Messaging répètent des requêtes d'appartenance partielles. Certaines opérations ne vérifient aucune appartenance au cercle, notamment l'annuaire et la publication des clés d'appareil. La création d'une conversation écrit avant de vérifier que l'acteur et tous les participants appartiennent au cercle. Les autorisations REST et Socket.IO ne partagent pas une même définition, et le schéma ne représente pas encore le rôle administrateur décidé pour la V1.

Ces écarts permettent l'accès croisé à des métadonnées ou des clés publiques, l'insertion de participants extérieurs et des divergences de comportement entre transports.

## Objectif mesurable

- Définir une matrice unique et testable pour les rôles `owner`, `admin` et `member`.
- Faire passer toutes les décisions d'accès cercle/conversation/clé et les abonnements Socket.IO par le service ACL.
- Refuser une cible inaccessible avec une réponse générique qui ne confirme pas inutilement son existence.
- Vérifier l'acteur et tous les participants avant toute écriture de conversation.
- Représenter le rôle administrateur par une migration SQL versionnée et réversible.
- Ne pas ajouter d'aller-retour réseau au chemin nominal du client.

## Périmètre

- Service ACL et routes Messaging des cercles, conversations, messages et clés d'appareil.
- Abonnements et événements entrants Socket.IO liés à une conversation.
- Colonne de rôle de `user_groups`, migration et affectation `admin`/`member` par le propriétaire.
- Exposition du rôle courant dans les réponses cercle et adaptation minimale de l'écran des demandes d'adhésion.
- Tests négatifs de matrice et de routes.

## Hors périmètre

- Transactionnaliser toutes les décisions et écritures multi-étapes (`TC-105`).
- Preuve de possession, approbation et rotation des appareils (`TC-106`).
- Validation exhaustive des tailles et propriétés de payload (`TC-107`).
- Transfert de propriété, suppression ou sortie d'un cercle, dont les parcours seront finalisés avec le cycle compte/cercle.
- Baseline et choix définitif de l'outil de migration (`TC-201`) ; les scripts SQL de cette tâche devront y être repris sans perdre leur historique.

## Invariants affectés

- Invariant 1 : l'acteur vient exclusivement du sujet du jeton d'accès.
- Invariant 6 : toute lecture ou écriture vérifie appartenance et rôle côté serveur.
- Invariant 7 : la création de conversation doit au minimum refuser avant écriture ; l'atomicité générale reste dans `TC-105`.
- Invariant 8 : chaque rôle reçoit uniquement les capacités prévues.
- Invariant 9 : une cible inaccessible ne révèle pas son existence.
- Invariant 24 : le changement de schéma est versionné, testé et réversible.

## Matrice cible de cette tâche

| Action | Propriétaire | Administrateur | Membre |
|---|---:|---:|---:|
| Lire cercle, membres et annuaire de clés | oui | oui | oui |
| Publier/révoquer ses propres clés | oui | oui | oui |
| Créer une conversation avec des membres du cercle | oui | oui | oui |
| Lire/écrire une conversation dont il est participant | oui | oui | oui |
| Voir et traiter les demandes d'adhésion | oui | oui | non |
| Affecter le rôle administrateur/membre | oui | non | non |
| Voter collectivement sur une adhésion | non | non | non |

Le rôle propriétaire est dérivé de `groups.creator_id`, qui reste l'unique source de propriété. `user_groups.role` ne porte que `admin` ou `member`, ce qui empêche la création accidentelle de plusieurs propriétaires.

## Travail

1. Ajouter la migration réversible du rôle de membre.
2. Remplacer le service ACL partiel par une matrice typée et des helpers cercle/conversation.
3. Migrer toutes les routes REST concernées et les handlers Socket.IO.
4. Vérifier tous les membres ciblés avant l'insertion d'une conversation.
5. Restreindre les demandes d'adhésion aux propriétaires/administrateurs et désactiver le vote collectif hérité.
6. Permettre au propriétaire d'affecter `admin` ou `member` sans pouvoir modifier son propre rôle.
7. Exposer le rôle courant et masquer l'interface d'approbation aux simples membres.
8. Ajouter les tests négatifs et mettre à jour contrats et documentation.
9. Déployer et exercer uniquement `trust-circle-staging`, avec migration puis rollback prouvé.

## Critères d'acceptation

- [x] Une matrice exportée couvre explicitement les trois rôles et toutes les actions du tableau.
- [x] Aucun endpoint de clés d'un cercle n'est accessible à un non-membre.
- [x] Un membre simple ne peut ni voir ni traiter une demande d'adhésion, et la route de vote héritée est indisponible.
- [x] Propriétaire et administrateur peuvent voir et traiter les demandes ; seul le propriétaire peut changer un rôle.
- [x] Une conversation ne peut être créée que si l'acteur et chaque participant appartiennent au même cercle, avant toute insertion.
- [x] Lecture, message, accusé, lecteurs, abonnement et frappe exigent l'appartenance à la conversation et au cercle parent.
- [x] REST et Socket.IO utilisent le même service ACL ; les requêtes d'autorisation ad hoc ont disparu des routes/handlers concernés.
- [x] Les refus d'accès croisé sont génériques et n'émettent ni événement ni écriture.
- [x] La migration monte et redescend sur une base de test sans perte d'appartenance.
- [x] Tests et build Messaging passent, puis les scénarios négatifs passent sur `trust-circle-staging`.

## Tests et preuves attendues

- Tests unitaires exhaustifs de la matrice rôle/action.
- Tests Fastify négatifs : annuaire de clés hors cercle, création avec participant extérieur, lecture d'une conversation inaccessible, adhésion par membre simple et changement de rôle par non-propriétaire.
- Assertions qu'un refus précède insertion et émission Socket.IO.
- Tests Socket.IO ou tests du helper commun pour abonnement/frappe.
- `npm test`, `npm run build`, validation des scripts SQL et `git diff --check`.
- Smoke test PostgreSQL sur staging avec comptes et objets synthétiques, sans donnée réelle.

## Migration et rollback

Déployer d'abord la migration ajoutant `user_groups.role`, puis le service Messaging. Le rollback repointe d'abord l'application vers la version précédente, puis exécute le script descendant qui retire uniquement la colonne de rôle. Les appartenances `(user_id, group_id)` restent intactes. Aucune production n'est modifiée dans cette tâche.

## Résultat et preuves — 2026-08-25

- Implémentation applicative : commit `f0e1baa7db2cd9c0e0cfd1104f477af25eec5b9f`, poussé sur `main`.
- Local : Auth `17/17`, Messaging `28/28`, build TypeScript Messaging réussi, OpenAPI YAML sans doublon, liens documentaires valides, script shell valide et `git diff --check` propre.
- Flutter 3.47.1 : `13/13` tests réussis ; l'analyse ne relève aucune erreur de compilation, mais conserve 88 avertissements/informations préexistants et la configuration `.env` attendue hors dépôt.
- Migration : montée et descente exercées dans le schéma PostgreSQL isolé `tc104_migration_test` ; les deux appartenances synthétiques sont conservées, la valeur par défaut et la contrainte de rôle sont vérifiées.
- Sauvegarde avant changement : dump PostgreSQL vérifié `pre-tc104-20260825T110719Z.dump`, conservé sur le staging en mode `0600`.
- Staging LXC106 : migration appliquée, quatre services sains, révision des images Auth/Messaging vérifiée, aucun redémarrage ni log Messaging de niveau erreur observé après déploiement.
- Deux exécutions du smoke test ont réussi. La seconde couvre trois comptes synthétiques et prouve notamment le refus hors cercle, l'absence d'écriture après création de conversation refusée, le traitement owner/admin, le refus au membre simple et au non-propriétaire, la neutralisation du vote et l'isolation de l'annuaire de clés.
- Le client réutilise le rôle reçu dans les réponses cercle ; aucun aller-retour réseau supplémentaire n'est ajouté à la connexion ou au chargement des messages.
- Aucun environnement de production n'a été modifié et aucun secret n'a été affiché.

La migration est compatible avec la release précédente : le rollback applicatif peut repointer vers `8ebeaa30f243a010d22070b8de20d969adedba89`, puis le script descendant peut être appliqué. La configuration antérieure est conservée sous `staging.env.before-f0e1baa7db2c` en mode `0600`.

## Décisions humaines nécessaires

Aucune pour la matrice : les capacités proviennent des décisions V1 acceptées. Le transfert de propriété et l'interface complète de gestion des rôles restent à concevoir dans une tâche dédiée.
