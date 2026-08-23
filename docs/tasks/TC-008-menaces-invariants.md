# TC-008 — Établir menaces et invariants de sécurité

Statut : Terminée — baseline initiale
Priorité : P0
Dépendances : TC-007
Dernière preuve : 2026-08-23

## Objectif

Établir les actifs, adversaires, abus et règles non négociables qui guideront les tâches backend, crypto, client et infrastructure.

## Livré

- `docs/security/THREAT_MODEL.md` : périmètre, actifs, adversaires, menaces, contrôles, scénarios et risques résiduels.
- `docs/security/SECURITY_INVARIANTS.md` : 30 invariants numérotés.
- `docs/security/CRYPTO_PROTOCOL.md` : état V2, limites et exigences V3.
- Liens dans `AGENTS.md`, stratégie de test et roadmap.

## Critères d'acceptation

- [x] Identité, JWT, ACL, appareils, clés, messages, stockage, fiabilité et production sont couverts.
- [x] Les invariants connus comme violés par le prototype sont explicites.
- [x] Les limites de l'E2EE et les métadonnées sont décrites honnêtement.
- [x] Les scénarios critiques peuvent devenir des tests de non-régression.
- [x] La décision crypto reste ouverte dans une ADR dédiée.

## Suivi obligatoire

La baseline n'est pas un audit indépendant. Elle doit être mise à jour après TC-002, avant/pendant TC-301, lors de toute collecte tierce et avant le pentest. Chaque tâche Phase 1 doit citer les invariants qu'elle restaure et fournir des tests négatifs.
