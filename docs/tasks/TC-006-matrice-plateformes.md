# TC-006 — Décider la matrice plateformes et versions minimales

Statut : Terminée — matrice de conception acceptée, preuves d'implémentation reportées
Priorité : P0
Décision : propriétaire du produit
Dépendances : TC-005

## Objectif

Fixer les OS, architectures et appareils réellement supportés afin de sélectionner des dépendances compatibles et de construire une matrice CI/test réaliste.

## Décision acceptée le 2026-08-23

- Android : Android 9/API 28 minimum ; API 36 comme cible haute initiale.
- iOS/iPadOS : iOS/iPadOS 15 minimum.
- Windows : Windows 11 25H2 x64 minimum.
- macOS : macOS 14 arm64 souhaité, non bloquant et non annoncé sans preuve physique.
- Site public : site statique sans stockage de clé de messagerie, compatible avec les navigateurs evergreen définis dans le registre.

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
- [x] Les builds et probes stockage/réseau obligatoires sont spécifiés, attribués et bloquent leur gate de plateforme ; aucune compatibilité exécutée n'est revendiquée dans cette tâche de décision.
- [x] La matrice CI et appareils manuels requise est définie avec responsable.
- [x] Les exigences stores utilisées ont source et date de vérification.
- [x] Le coût macOS et sa position de lancement sont tranchés.

## Livrables

- Mise à jour de `docs/quality/TEST_STRATEGY.md`.
- Registre de compatibilité des plugins sous `docs/architecture/`.
- Tâches `TC-701` à `TC-707` raffinées.

## Résultat du 2026-08-24

- Matrice décidée : Android 9/API 28, iOS/iPadOS 15, Windows 11 25H2 x64 ; macOS 14 arm64 souhaité et non bloquant.
- Exigences Flutter, Google Play, Apple, Microsoft Store et runners CI vérifiées sur sources officielles.
- Registre créé dans `docs/architecture/PLATFORM_COMPATIBILITY.md` et stratégie de test détaillée.
- Tâches `TC-701` à `TC-707` raffinées.

TC-006 fixe une matrice de conception et de test, pas une preuve prématurée de compatibilité de l'application actuelle. Flutter/Dart ne sont pas installés sur l'hôte courant, aucun runner Windows/macOS n'est localement accessible, et l'application a des bloqueurs réels (`.env`/secret partagé, SQLite en clair et incompatible Windows, initialisations de plugins incomplètes). Aucun faux `.env` ne sera créé pour simuler un build réussi.

La réalisation des preuves est reportée aux tâches qui rendent ces tests possibles : `TC-109` pour la suppression du secret public, `TC-306` pour le stockage sécurisé, `TC-505`/`TC-508` pour la reprise réseau, `TC-701` à `TC-706` pour chaque plateforme et `TC-707` pour la matrice CI. Ces tâches ne peuvent être clôturées sans leurs preuves respectives.

## Preuves de plateforme reportées, non revendiquées

- Caractéristiques exactes de l'Android disponible : modèle, version, API et architecture.
- Caractéristiques exactes du PC Windows 11 disponible : édition, version/build et architecture.
- Probe stockage/réseau réussi sur Android, iOS et Windows.
- Builds sans signature réussis sur Android, iOS et Windows après séparation de la configuration publique et suppression du secret partagé.
- Preuve macOS avant toute annonce de disponibilité macOS.

L'absence de ces preuves ne bloque plus la décision de matrice ni le démarrage de la Phase 1. Elle bloque en revanche toute déclaration de compatibilité, bêta ou publication sur la plateforme concernée.

## Inventaire déclaré le 2026-08-24

- Disponible maintenant : un appareil Android et un PC Windows 11, utilisés comme cibles physiques principales de développement.
- Non disponible maintenant : iPhone/iPad et Mac.
- Le propriétaire pourra organiser des tests Apple ultérieurement.
- Stratégie : CI/simulateurs Apple pendant le développement, puis iPhone physique obligatoire avant bêta iOS. macOS reste non bloquant et ne sera annoncé qu'après accès à un Mac Apple Silicon et validation réelle.
