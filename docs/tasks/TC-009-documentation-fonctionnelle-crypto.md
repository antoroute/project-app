# TC-009 — Documenter le fonctionnement et la cryptographie

Statut : Terminée
Priorité : P0 documentation sécurité
Décision : mainteneur
Dépendances : TC-007, TC-008

## Contexte et problème

La documentation actuelle couvre la vision, l'architecture générale, le modèle de menace et une description sommaire des primitives V2. Elle ne permet toutefois pas de reconstruire précisément les parcours applicatifs, les flux de données, le cycle des clés ou le format effectivement signé et chiffré. Certains documents mélangent aussi état courant et cible V1.

Cette lacune rend les revues de sécurité, les évolutions assistées et la future migration V3 plus risquées. Elle peut également conduire à présenter comme acquise une propriété que le code ne fournit pas encore.

## Objectif mesurable

- Fournir un point d'entrée unique vers la documentation fonctionnelle complète de l'application actuelle.
- Décrire chaque parcours implémenté du client jusqu'au stockage et aux événements temps réel.
- Spécifier le protocole cryptographique V2 à partir du code : clés, tailles, stockage, dérivation, enveloppe, signature, chiffrement, déchiffrement et caches.
- Séparer explicitement comportement observé, comportement cible et fonctionnalité non implémentée.
- Relier chaque sous-système à son code, ses données, ses invariants, ses limites et sa tâche corrective.

## Périmètre

- Client Flutter, Auth, Messaging, PostgreSQL et staging.
- Comptes/sessions, cercles, adhésion, appareils, conversations, messages, temps réel, stockage local et notifications.
- Cryptographie applicative E2EE V2 et cryptographie des JWT/caches.
- Index documentaire et matrice de traçabilité.

## Hors périmètre

- Corriger les vulnérabilités découvertes pendant la rédaction ; elles sont documentées et routées vers les tâches de développement appropriées.
- Décider ou implémenter le protocole V3 (`TC-301`).
- Produire un audit cryptographique indépendant ou revendiquer une conformité à Signal/MLS.
- Documenter comme disponibles les fonctions hors V1 ou encore factices.

## Invariants affectés

- Invariants 1 à 5 : identité, jetons et secrets.
- Invariants 10 à 20 : appareils, clés et messages E2EE.
- Invariants 21 à 25 : stockage, synchronisation et rétention.
- Invariant 30 : les déclarations doivent refléter le comportement réel.

## Travail

1. Inventorier composants, routes, événements, tables, stockages et parcours UI.
2. Écrire la référence fonctionnelle « tel qu'implémenté ».
3. Écrire la spécification technique du protocole V2 et de ses deux chemins de déchiffrement.
4. Documenter les frontières de visibilité et de confiance.
5. Créer une matrice de traçabilité vers le code, les risques et la roadmap.
6. Corriger les références d'architecture devenues obsolètes et mettre à jour les index.
7. Vérifier les liens, la syntaxe Markdown, les références de fichiers et la cohérence des statuts.

## Critères d'acceptation

- [x] Tous les parcours utilisateur implémentés ont un flux client/API/données/temps réel documenté.
- [x] Chaque clé et secret possède origine, portée, stockage, usage, durée et visibilité documentés.
- [x] L'enveloppe V2 et les octets signés sont décrits champ par champ sans ambiguïté volontaire.
- [x] Les chemins de déchiffrement normal et rapide sont distingués, avec leur ordre réel vérification/affichage.
- [x] Les métadonnées visibles par Auth, Messaging, PostgreSQL et le client sont explicites.
- [x] Les écarts de sécurité connus sont visibles et reliés à une tâche corrective.
- [x] La documentation distingue systématiquement observé, cible et non implémenté.
- [x] Les index et liens internes sont valides.

## Tests et preuves attendues

- Inventaire automatisé des routes, événements et tables comparé aux documents.
- Vérification des liens Markdown relatifs et des chemins de code cités.
- `git diff --check` et revue des termes normatifs/garanties.
- Aucun secret réel ni contenu utilisateur dans la documentation.

## Migration et rollback

Cette tâche ne modifie ni code, ni schéma, ni environnement. Le rollback consiste à retirer les documents et liens du commit ; aucune donnée ou session n'est affectée.

## Décisions humaines nécessaires

Aucune pour documenter l'état courant. Le choix du protocole V3 et l'ordre de correction des risques restent soumis aux tâches de sécurité correspondantes.

## Résultat et preuves

- Référence fonctionnelle : `docs/architecture/FUNCTIONAL_REFERENCE.md`.
- Spécification V2 observée : `docs/security/CRYPTOGRAPHY_V2.md`.
- Matrice code/données/tâches : `docs/architecture/TRACEABILITY.md`.
- Le risque d'utilisation de texte avant vérification est isolé dans `TC-114` avec contrainte de performance explicite.
- Inventaires extraits du code : 25 routes HTTP (deux `/health` partagent le même chemin), 12 tables PostgreSQL et événements Socket.IO comparés au document.
- Vérification locale : liens relatifs valides sur 61 fichiers Markdown et `git diff --check` sans erreur le 2026-08-24.
- Aucun test applicatif exécuté : le changement est documentaire et ne modifie ni application, ni schéma, ni staging.
