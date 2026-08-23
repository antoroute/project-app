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
