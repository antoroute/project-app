# TC-703 — Rendre le stockage Windows compatible et sûr

Statut : À faire
Priorité : P0 Windows
Décision : revue sécurité requise
Dépendances : TC-006, TC-306, TC-602

## Objectif

Remplacer l'usage direct de `sqflite` par une abstraction fonctionnant sur Windows 11 x64 et prouver que messages, outbox et caches ne sont pas lisibles comme une base SQLite en clair.

## Travail

- Définir une interface unique de base locale et migrations testables.
- Sélectionner une implémentation chiffrée maintenue pour Android/iOS/Windows/macOS après spike comparatif.
- Générer la clé par CSPRNG, la protéger avec le stockage OS, isoler comptes/appareils et prévoir effacement.
- Échouer fermé si le moteur chiffré attendu n'est pas chargé ; aucun fallback silencieux en clair.
- Tester migration depuis le prototype seulement si des données doivent finalement être conservées.

## Critères d'acceptation

- [ ] Probe Windows 11 25H2 x64 : créer, redémarrer, relire, effacer.
- [ ] SQLite standard ne peut pas lire le fichier et le moteur vérifie explicitement son mode chiffré.
- [ ] Tests concurrence, corruption, mauvaise clé, compte multiple et désinstallation passent.
- [ ] Aucun contenu, clé ou token n'apparaît dans logs, fichiers temporaires ou crash dumps de test.
- [ ] Android/iOS ne régressent pas avec la même abstraction.

## Rollback

Conserver l'ancien lecteur uniquement dans un outil de migration hors parcours normal ; revenir au commit précédent si la migration n'est pas démontrée, sans réactiver un stockage en clair.
