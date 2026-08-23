# Stratégie de test

Statut : cible V1
Dernière mise à jour : 2026-08-23

## Pyramide

- Unitaires : règles d'autorisation, tokens, sérialisation, machines d'état, validateurs, modèles Flutter.
- Intégration : routes Fastify + PostgreSQL réel éphémère, migrations, outbox/sync, stockage sécurisé abstrait.
- Contrat : OpenAPI, événements Socket.IO, compatibilité versions et erreurs.
- End-to-end : comptes, cercles, appareils et messages sur backend isolé.
- Plateforme : notifications, stockage, verrouillage biométrique, deep links, cycle de vie et installation/mise à jour.
- Sécurité : tests négatifs systématiques, fuzzing des parseurs, dépendances, secrets et analyse statique.
- Opérations : sauvegarde/restauration, rollback, perte réseau, redémarrage et saturation contrôlée.

## Cas prioritaires

Chaque route protégée reçoit au minimum : sans jeton, jeton expiré, refresh utilisé comme access, mauvais issuer/audience/type, non-membre, membre sans rôle, objet inexistant, corps forgé et concurrence pertinente.

Chaque enveloppe crypto reçoit : vecteur valide, bit modifié par champ, mauvaise conversation/cercle/appareil, clé révoquée, rejeu, version inconnue, taille excessive, Unicode multi-octets et ordre de champs différent.

La synchronisation couvre : timeout avant/après persistance, retry, redémarrage, déconnexion prolongée, messages concurrents, curseur ancien, doublons réseau, changement d'appareil et changement de compte.

## Matrice de plateformes

Versions et architectures de référence : `docs/architecture/PLATFORM_COMPATIBILITY.md`.

| Niveau | Android 9/API 28 à Android 16/API 36 | iOS/iPadOS 15 à 26 | Windows 11 25H2+ x64 | macOS 14+ arm64 |
|---|---|---|---|---|
| Analyse/tests Dart | Ubuntu 24.04 | partagé | partagé | partagé |
| Build sans signature | Ubuntu 24.04, API 36 | macOS 26/Xcode 26 | Windows 2025 | macOS 26/Xcode 26 |
| Tests intégration OS | émulateurs API 28 et 36 + appareils | simulateurs 15 et 26 + iPhone/iPad | VM 25H2 + poste x64 | Mac Apple Silicon avec macOS 14 et courant |
| Parcours manuel release | Android API 28 arm64 + Android courant | iPhone iOS 15 + iPhone courant ; iPad adaptatif | Windows 11 25H2 x64 | seulement avant annonce macOS |

### Responsabilités et fréquence

| Preuve | Responsable | Fréquence |
|---|---|---|
| format, analyse, tests Dart et build Android | CI maintenue avec l'assistant | chaque pull request concernée |
| builds iOS, Windows et macOS sans signature | CI maintenue avec l'assistant | branche principale et release candidate |
| probes stockage/réseau/biométrie/notification/deep link | CI + propriétaire sur appareils | changement de plugin et release candidate |
| installation, mise à jour, veille/reprise et accessibilité | propriétaire du produit | chaque release candidate |
| signature, stores, TestFlight/MSIX/notarisation | propriétaire, assisté | release candidate et publication |

L'inventaire des appareils réellement disponibles reste à renseigner dans `TC-006`. Une case sans appareil n'est jamais remplacée par une affirmation de compatibilité. La CI cible des labels explicites (`ubuntu-24.04`, `windows-2025`, `macos-26`) et une version Flutter exacte ; les labels `latest` ne sont pas utilisés dans la matrice contractuelle.

Les versions minimales sont décidées dans `TC-006`. Elles sont revérifiées dans `TC-801` avant publication, car les exigences stores évoluent.

## Gates proposés

- Pull request : format, lint, analyse, unitaires, intégration concernée, scan secrets/dépendances.
- Branche principale : contrats, E2E essentiels, build Android et images backend.
- Release candidate : matrice complète, restauration, migration/rollback, performance, accessibilité et revue sécurité.
- Publication : aucune vulnérabilité critique/haute exploitable non acceptée explicitement, aucun test essentiel instable, checklist signée.

## Traçabilité

Les tests portant un invariant de sécurité citent son numéro dans leur nom ou métadonnée. Une tâche décrit les tests ajoutés et les plateformes réellement exécutées ; « non testé faute d'outil » reste un risque ouvert.
