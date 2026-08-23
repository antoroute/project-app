# ADR-0003 — Protocole cryptographique V3

Statut : Proposée, décision non prise
Date : 2026-08-23
Décision attendue : phase crypto `TC-301`

## Contexte

Le protocole V2 combine de bons primitives mais reste un protocole maison incomplet, sans spécification indépendante, garanties modernes démontrées ni audit. Le multi-appareil et les groupes rendent une correction locale insuffisante.

## Options à évaluer

### A — MLS via une bibliothèque maintenue

Avantages : standard conçu pour les groupes, évolution de membres formalisée, objectifs de forward secrecy et post-compromise security, corpus d'interopérabilité.
Risques : maturité/portabilité des bibliothèques Flutter, intégration native sur quatre OS, complexité opérationnelle et migration.

### B — Bibliothèque/protocole de messagerie éprouvé autre que MLS

Avantages : écosystème potentiellement plus mûr pour le pair-à-pair et multi-appareil.
Risques : adaptation aux groupes, licences, bindings et modèle serveur.

### C — V3 interne minimale, spécifiée puis auditée

Avantages : contrôle de l'intégration et migration ciblée.
Risques : coût élevé de conception, maintenance et audit ; probabilité d'erreur supérieure ; propriétés FS/PCS difficiles.

### D — Corriger V2 sans changement de protocole

Avantages : effort initial réduit.
Risques : dette structurelle et garanties insuffisantes. Cette option ne peut être retenue pour une promesse de sécurité moderne sans justification et audit exceptionnels.

## Preuves requises avant décision

- Prototype sur Android, iOS, Windows et macOS pour chaque bibliothèque candidate sérieuse.
- Évaluation licence, maintenance, taille, performances, sauvegarde et recovery.
- Modèle de menace et diagramme du cycle membre/appareil.
- Vecteurs de tests reproductibles et stratégie de migration V2 → V3.
- Estimation de l'audit indépendant et capacité de maintenance à long terme.

## Garde-fou

Aucune implémentation V3 ne commence sur la seule préférence d'un assistant. La comparaison est documentée, revue puis acceptée explicitement par le propriétaire.
