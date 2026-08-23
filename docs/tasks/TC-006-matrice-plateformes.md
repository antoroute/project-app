# TC-006 — Décider la matrice plateformes et versions minimales

Statut : En cours — matériel partiellement inventorié, preuves sur cibles manquantes
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

- [x] Tableau OS/version/architecture accepté et daté.
- [x] Chaque dépendance critique a une compatibilité documentée par son éditeur ou une tâche de remplacement.
- [ ] Un build minimal et un test stockage/réseau passent sur chaque cible obligatoire.
- [x] La matrice CI et appareils manuels requise est définie avec responsable.
- [x] Les exigences stores utilisées ont source et date de vérification.
- [x] Le coût macOS et sa position de lancement sont tranchés.

## Livrables

- Mise à jour de `docs/quality/TEST_STRATEGY.md`.
- Registre de compatibilité des plugins sous `docs/architecture/`.
- Tâches `TC-701` à `TC-707` raffinées.

## Résultat intermédiaire du 2026-08-23

- Matrice décidée : Android 9/API 28, iOS/iPadOS 15, Windows 11 25H2 x64 ; macOS 14 arm64 souhaité et non bloquant.
- Exigences Flutter, Google Play, Apple, Microsoft Store et runners CI vérifiées sur sources officielles.
- Registre créé dans `docs/architecture/PLATFORM_COMPATIBILITY.md` et stratégie de test détaillée.
- Tâches `TC-701` à `TC-707` raffinées.

La tâche ne peut pas être déclarée terminée : Flutter/Dart ne sont pas installés sur l'hôte courant, aucun runner Windows/macOS n'est localement accessible, et l'application actuelle a des bloqueurs réels (`.env`/secret partagé, SQLite en clair et incompatible Windows, initialisations de plugins incomplètes). Aucun faux `.env` ne sera créé pour simuler un build réussi.

## Preuves encore requises

- Caractéristiques exactes de l'Android disponible : modèle, version, API et architecture.
- Caractéristiques exactes du PC Windows 11 disponible : édition, version/build et architecture.
- Probe stockage/réseau réussi sur Android, iOS et Windows.
- Builds sans signature réussis sur Android, iOS et Windows après séparation de la configuration publique et suppression du secret partagé.
- Preuve macOS avant toute annonce de disponibilité macOS.

## Inventaire déclaré le 2026-08-24

- Disponible maintenant : un appareil Android et un PC Windows 11, utilisés comme cibles physiques principales de développement.
- Non disponible maintenant : iPhone/iPad et Mac.
- Le propriétaire pourra organiser des tests Apple ultérieurement.
- Stratégie : CI/simulateurs Apple pendant le développement, puis iPhone physique obligatoire avant bêta iOS. macOS reste non bloquant et ne sera annoncé qu'après accès à un Mac Apple Silicon et validation réelle.
