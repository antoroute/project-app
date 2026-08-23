# TC-701 — Préparer Android pour la publication

Statut : À faire
Priorité : P0 release
Décision : propriétaire du produit
Dépendances : TC-001, TC-006, TC-611

## Objectif

Produire un AAB Android installable et publiable pour API 28 à 36, sans secret embarqué et avec identité, permissions et signature de release définitives.

## Travail

- Remplacer l'identifiant `com.example` après TC-001 et définir versioning/application label.
- Fixer `minSdk 28`, `targetSdk 36` et `compileSdk >= 36`; vérifier JDK/AGP/Gradle.
- Réduire les permissions à celles effectivement utilisées et documenter caméra, notifications et biométrie.
- Séparer configuration publique et secrets ; supprimer `.env` des assets et toute clé partagée.
- Configurer App Links, icônes, splash, AAB, symboles et signature hors dépôt.
- Tester cycle de vie, stockage chiffré, notifications génériques et reprise réseau sur API 28 et 36.

## Critères d'acceptation

- [ ] `flutter analyze`, tests et build AAB release réussissent avec la version Flutter figée.
- [ ] Aucun secret ou certificat privé n'est présent dans l'AAB ou le dépôt.
- [ ] Installation, mise à jour et désinstallation passent sur API 28 et 36.
- [ ] App Links, caméra optionnelle, biométrie et notifications refusées/acceptées sont testés.
- [ ] Play pre-launch report ne révèle aucun blocage critique.

## Preuves

Logs CI assainis, hash de l'AAB, rapport de permissions, captures Play Console sans donnée personnelle et fiche d'appareils utilisés.
