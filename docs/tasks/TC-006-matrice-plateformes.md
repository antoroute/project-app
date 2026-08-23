# TC-006 — Décider la matrice plateformes et versions minimales

Statut : Prête après décision initiale de TC-005
Priorité : P0
Décision : propriétaire du produit
Dépendances : TC-005

## Objectif

Fixer les OS, architectures et appareils réellement supportés afin de sélectionner des dépendances compatibles et de construire une matrice CI/test réaliste.

## Base à évaluer, pas encore acceptée

- Android : API 24 ou supérieure, avec revue des exigences Play en vigueur.
- iOS : iOS 15 ou supérieur.
- Windows : Windows 10/11 ou Windows 11 uniquement selon support éditeur, Flutter et cible utilisateur.
- macOS : macOS 12 ou supérieur si inclus.

Ces candidats proviennent du cadrage initial ; les politiques stores et supports OS doivent être vérifiés à la date d'exécution.

## Travail

1. Inventorier les contraintes Flutter/Dart et de chaque plugin sur les quatre plateformes.
2. Vérifier les exigences SDK/target des stores à date sur sources officielles.
3. Prototyper les points à risque : SQLite chiffré, secure storage, biométrie, notifications, deep links/invitations, sockets et cycle de vie.
4. Choisir architectures CPU, versions minimales et navigateurs du seul site statique.
5. Définir appareils/VM physiques disponibles pour tests manuels.
6. Estimer la part d'utilisateurs exclue et le coût de support.
7. Mettre à jour ADR-0001 si macOS devient obligatoire ou reporté.

## Critères d'acceptation

- [ ] Tableau OS/version/architecture accepté et daté.
- [ ] Chaque dépendance critique a une compatibilité prouvée ou une tâche de remplacement.
- [ ] Un build minimal et un test stockage/réseau passent sur chaque cible obligatoire.
- [ ] La matrice CI et appareils manuels est définie avec responsable.
- [ ] Les exigences stores utilisées ont source et date de vérification.
- [ ] Le coût macOS et sa position de lancement sont tranchés.

## Livrables

- Mise à jour de `docs/quality/TEST_STRATEGY.md`.
- Registre de compatibilité des plugins sous `docs/architecture/`.
- Tâches `TC-701` à `TC-707` raffinées.
