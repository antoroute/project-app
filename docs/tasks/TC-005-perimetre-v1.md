# TC-005 — Geler le périmètre V1

Statut : Prête
Priorité : P0
Décision : propriétaire du produit
Dépendances : aucune

## Objectif

Transformer `docs/product/V1_SCOPE.md` en engagement testable et empêcher l'ajout opportuniste de fonctionnalités avant que sécurité et fiabilité soient prêtes.

## Décisions à prendre

1. Les conversations appartiennent-elles toutes à un cercle ?
2. Rôles : propriétaire/admin/membre ou modèle plus simple ?
3. Qui approuve membre et appareil : un admin, le propriétaire, quorum ?
4. Quel historique reçoit un nouvel appareil ?
5. Que devient l'historique après perte totale et récupération de compte ?
6. macOS est-il requis le jour du lancement ou juste après la V1 obligatoire ?
7. Faut-il des messages individuels hors cercle en V1 ?
8. Quelle durée de conservation serveur et locale par défaut ?

## Travail

- Décrire 2 à 4 personas et leurs parcours essentiels.
- Pour chaque fonction incluse, écrire résultat utilisateur et condition d'échec acceptable.
- Pour chaque exclusion, placer les idées dans une liste post-V1 sans architecture prématurée.
- Définir les métriques de bêta sans contenu ni télémétrie invasive.
- Examiner les dépendances entre scope, modération, stores, crypto et récupération.
- Accepter/remplacer `ADR-0002` et passer `V1_SCOPE.md` au statut accepté.

## Critères d'acceptation

- [ ] Chaque question ci-dessus a une décision enregistrée.
- [ ] Les parcours compte/cercle/appareil/message/suppression sont décrits sans ambiguïté majeure.
- [ ] Calendrier, fichiers, localisation, appels, Web messaging et monétisation sont confirmés inclus ou exclus.
- [ ] Les critères de « publiable » et de bêta sont mesurables.
- [ ] La roadmap et les tâches incompatibles sont mises à jour.
- [ ] Toute nouvelle demande hors V1 exige une décision explicite de changement de scope.

## Validation

Atelier court propriétaire + assistant à partir du document, puis revue écrite. Aucun code n'est nécessaire pour clore cette tâche.
