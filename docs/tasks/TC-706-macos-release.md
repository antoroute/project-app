# TC-706 — Valider la cible macOS optionnelle

Statut : À faire, non bloquante pour la V1 obligatoire
Priorité : P1
Décision : propriétaire après prototype
Dépendances : TC-006, TC-611, TC-703

## Objectif

Décider si macOS 14+ Apple Silicon peut être annoncé sans retarder Android/iOS/Windows, puis produire une application signée/notarisée si la preuve est positive.

## Travail

- Fixer deployment target 14 et architecture arm64 uniquement.
- Configurer sandbox, réseau client, Keychain, caméra, notifications et Associated Domains.
- Réutiliser l'abstraction de stockage chiffré et le parcours d'invitation par lien/code.
- Tester build, signature, notarisation, installation, update et Gatekeeper.
- Estimer le coût récurrent du runner/appareil et décider Go/Report.

## Critères d'acceptation

- [ ] Tous les probes de `PLATFORM_COMPATIBILITY.md` passent sur Mac Apple Silicon.
- [ ] Archive signée/notarisée installable sur macOS 14 et courant.
- [ ] Aucun droit sandbox superflu et aucune donnée en clair.
- [ ] Une décision explicite annonce macOS ou le reporte sans bloquer la V1.

## Rollback

Ne pas publier ni afficher de lien macOS si une preuve manque ; le retrait de la cible ne modifie pas les trois plateformes obligatoires.
