# Fiches de tâches

Les fiches transforment la roadmap en unités confiables pour un développement assisté. Une seule fiche principale est fournie à l'assistant par intervention, avec les documents liés.

## Index Phase 0

- [TC-001 — Nom et identité](TC-001-nom-identite.md)
- [TC-002 — Inventaire VM](TC-002-inventaire-vm.md)
- [TC-003 — Sauvegarde/restauration](TC-003-sauvegarde-restauration.md)
- [TC-004 — Staging](TC-004-staging.md)
- [TC-005 — Périmètre V1](TC-005-perimetre-v1.md)
- [TC-006 — Matrice plateformes](TC-006-matrice-plateformes.md)
- [TC-007 — Socle documentaire IA](TC-007-socle-documentaire.md)
- [TC-008 — Menaces et invariants](TC-008-menaces-invariants.md)
- [TC-009 — Documentation fonctionnelle et cryptographique](TC-009-documentation-fonctionnelle-crypto.md)

## Index Phase 1

- [TC-101 — Configuration critique](TC-101-configuration-critique.md)
- [TC-102 — JWT access/refresh](TC-102-jwt-access-refresh.md)
- [TC-103 — Identité dérivée côté serveur](TC-103-identite-serveur.md)
- [TC-104 — Matrice ACL cercle/conversation/rôle](TC-104-matrice-acl.md)
- [TC-105 — Atomicité des contrôles et écritures](TC-105-atomicite-controles-ecritures.md)
- [TC-114 — Vérification avant utilisation](TC-114-verification-avant-utilisation.md)

## Format obligatoire des nouvelles fiches

- Identifiant, statut, priorité, responsable de décision et dépendances.
- Contexte et problème, sans inclure de secret.
- Objectif mesurable et hors périmètre.
- Fichiers/composants pressentis, sans imposer une solution prématurée.
- Critères d'acceptation vérifiables.
- Plan de tests et preuves attendues.
- Risques, migration, rollback et documentation à mettre à jour.
- Décisions humaines nécessaires.

## Taille

Une fiche doit idéalement produire une seule évolution révisable. Si elle mélange schéma, protocole, UI et production, la découper. Une tâche critique inclut ses tests de non-régression et n'est pas close par une simple compilation.

## Index Phase 7 — Plateformes

- [TC-701 — Android release](TC-701-android-release.md)
- [TC-702 — iOS/iPadOS release](TC-702-ios-release.md)
- [TC-703 — Stockage Windows](TC-703-windows-stockage.md)
- [TC-704 — Invitations Windows](TC-704-windows-invitations.md)
- [TC-705 — Distribution Windows](TC-705-windows-distribution.md)
- [TC-706 — macOS optionnel](TC-706-macos-release.md)
- [TC-707 — CI plateformes](TC-707-ci-plateformes.md)
