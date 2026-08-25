# TC-106 — Sécuriser le cycle de confiance des appareils

Statut : En cours — lot A terminé, lot B en validation
Priorité : P0 sécurité et identité cryptographique
Décision : propriétaire pour l'architecture d'approbation, mainteneur pour l'implémentation
Dépendances : TC-104, TC-105

## Contexte et problème

Le client utilise actuellement un identifiant d'installation global à tous les comptes. Les clés Ed25519/X25519 par cercle sont donc indirectement partagées dans un espace de noms qui ne contient pas explicitement le compte. Une clé absente, partielle ou corrompue peut en outre être supprimée puis régénérée silencieusement, ce qui change l'identité cryptographique, rend des messages historiques illisibles et peut publier une nouvelle clé sans explication utilisateur.

Le backend accepte une clé publique du sujet JWT sans preuve que le client possède la clé privée correspondante. Il ne possède pas non plus de registre d'appareils au niveau du compte permettant à un appareil déjà autorisé d'approuver un nouvel appareil.

## Objectif mesurable

- Isoler identifiant, clés et caches par compte authentifié.
- Ne jamais régénérer silencieusement une identité cryptographique existante ou partiellement perdue.
- Définir puis implémenter une preuve de possession rejouable zéro fois et une approbation par un appareil actif du même compte.
- Propager rotation et révocation à tous les cercles sans réactiver une clé révoquée.
- Conserver le choix V1 : un nouvel appareil ne reçoit que les futurs messages.

## Découpage obligatoire

### Lot A — Fondation locale sans changement de protocole

- Remplacer l'identifiant global `device_id_v1` par un identifiant stable propre au compte.
- Ne pas migrer automatiquement l'identifiant global, puisqu'il peut avoir été partagé par plusieurs comptes.
- Faire échouer explicitement le chargement de clés absentes, partielles, invalides ou incohérentes.
- Vider tous les caches d'identité cryptographique lors d'un changement de compte ou d'une déconnexion.
- Ajouter des tests unitaires du cloisonnement et du comportement fail-closed.

### Lot B — Registre et preuve de possession backend

- Décision préalable de l'ADR-0005.
- Registre d'appareils au niveau du compte, états `pending|active|revoked` et clés d'identité publiques.
- Challenge aléatoire à usage unique, expirant, lié au compte/appareil/clé et signé par le nouvel appareil.
- Bootstrap borné du premier appareil ; les appareils suivants restent `pending`.

Implémentation : registre `account_devices`, challenges à usage unique, transcription binaire V1, preuve Ed25519 et liste des appareils du sujet. Le détail normatif est dans `docs/security/DEVICE_TRUST_PROTOCOL_V1.md`.

### Lot C — Approbation et expérience multi-appareil

- Approbation signée par un appareil actif du même compte.
- Écran compréhensible sur l'ancien et le nouvel appareil, avec nom de plateforme et empreinte courte.
- Aucun secret ou ancien message transmis par le serveur ; activation uniquement pour les futurs messages.

### Lot D — Rotation, révocation et propagation

- Rotation versionnée sans remplacement ambigu d'une clé historique.
- Révocation globale empêchant immédiatement nouveaux envois/réceptions pour cet appareil.
- Invalidation déterministe des annuaires/caches et reprise utilisateur sans boucle lente.
- Tests de concurrence, rejeu, expiration, rollback et propagation sur staging.

## Hors périmètre

- Choix ou implémentation du protocole de messages V3 (`TC-301` à `TC-312`).
- Transfert de l'historique chiffré vers un nouvel appareil.
- Récupération après perte de tous les appareils (`TC-402` à `TC-404`).
- Attestation matérielle Apple/Google/Microsoft ; la preuve porte sur la possession de la clé applicative.
- Chiffrement complet de SQLite et durcissement exhaustif du stockage local (`TC-306`). Le lot A corrige néanmoins la clé maître prévisible et le croisement intercompte du cache de clés de message.

## Invariants affectés

- Invariant 10 : preuve de contrôle et approbation avant activation.
- Invariant 11 : rattachement au compte et séparation des caches.
- Invariant 12 : révocation immédiate et propagation déterministe.
- Invariant 13 : conservation fail-closed des clés privées locales.
- Invariant 14 : CSPRNG pour identifiants, clés et challenges.
- Invariant 24 : toute table ou contrainte nouvelle est migrée et réversible.

## Critères d'acceptation du lot A

- [x] Deux comptes utilisés sur la même installation obtiennent deux identifiants différents et stables.
- [x] L'ancienne clé globale n'est jamais réutilisée implicitement.
- [x] Les espaces de stockage et caches de clés ne peuvent pas se croiser entre comptes.
- [x] Une paire complète absente peut être créée uniquement par l'appel explicite de création.
- [x] Une paire partielle, invalide ou dont la clé publique ne correspond pas au seed échoue sans suppression ni écriture.
- [x] Les méthodes de signature/déchiffrement ne génèrent jamais une clé manquante.
- [x] Déconnexion ou changement de sujet vide les caches mémoire d'identifiant et de clés.
- [x] Tests Flutter, analyse statique et formatage réussissent.

## Résultat du lot A

- `device_id_v2:account:<userId>` remplace la sélection de l'identifiant global ; l'UUID du compte et celui de l'appareil sont validés avant usage.
- `KeyManagerFinal` sépare création explicite et chargement, sérialise les créations concurrentes et refuse tout matériel partiel, invalide ou incohérent sans le supprimer.
- L'enveloppe vérifiée transporte désormais le destinataire attendu. Les caches mémoire et SQLite de clés de message sont indexés par utilisateur, appareil et message ; l'appelant ne peut pas substituer ces valeurs lors de l'écriture.
- La clé maître du cache persistant est propre au compte et générée par `Random.secure()` ; les anciennes clés maîtres globales ne sont pas sélectionnées.
- La déconnexion et le changement de sujet purgent les identifiants, paires privées, clés de message, annuaire public et textes déchiffrés en mémoire.

Preuves locales du 2026-08-25 : formatage des fichiers Dart touchés ; `dart analyze lib test` sans erreur ni avertissement (85 informations historiques) ; 24 tests ciblés de sécurité et cryptographie réussis avec Flutter 3.47.1. Aucun changement backend, schéma ou staging dans ce lot.

## Validation des lots suivants

- Vecteurs de preuve positifs et négatifs indépendants du client Flutter.
- Rejet d'une signature altérée, d'un challenge expiré, consommé, d'un autre compte ou d'un autre appareil.
- Une session volée sans clé privée ne peut ni activer ni approuver un appareil.
- Deux bootstraps/paires d'approbations concurrents ont un seul résultat valide.
- Une révocation concurrente gagne toujours sur publication/rotation et bloque les nouveaux messages.
- Smoke tests réels sur `trust-circle-staging`, avec sauvegarde et rollback avant migration.

## Critères d'acceptation du lot B

- [x] L'option A est acceptée dans l'ADR-0005 et séparée du protocole de messages V3.
- [x] Le schéma montant et descendant du registre/challenges est versionné.
- [x] Le challenge est CSPRNG, expire après 5 minutes et lie compte, appareil, clé et expiration.
- [x] La signature Ed25519 porte sur une transcription binaire documentée et testée par vecteur figé.
- [x] Une signature invalide, un rejeu, une expiration ou un autre compte n'active aucun appareil.
- [x] Deux preuves concurrentes ne peuvent produire qu'un seul bootstrap actif.
- [x] Une session sans clé privée ne peut pas inscrire un appareil prouvé.
- [x] Un access token volé ne peut pas bootstrap une clé choisie sans réauthentification par mot de passe.
- [x] Les créations sont bornées par compte, appareil et nombre de challenges actifs.
- [ ] La migration montée/descente et les routes sont validées sur PostgreSQL staging après sauvegarde.
- [ ] Les healthchecks, smoke tests et vérifications SQL staging réussissent après déploiement.

## Migration et compatibilité

Le lot A conserve les données locales historiques mais cesse de les sélectionner. Il ne les supprime pas automatiquement : une future migration explicite devra prouver à quel compte elles appartiennent ou les laisser inaccessibles. Cela peut imposer une nouvelle inscription d'appareil aux utilisateurs du prototype, acceptable avant publication et préférable à un rattachement silencieux au mauvais compte.

Les lots backend utiliseront des migrations expand/contract compatibles avec la release précédente. Aucune donnée réelle n'est supprimée automatiquement.

## Risques résiduels pendant les lots A et B

Tant que les lots C et D ne sont pas terminés, le backend continue d'accepter les publications historiques `group_device_keys` sans exiger le nouveau registre. Le lot B prouve et enregistre l'identité de compte, mais l'approbation des appareils suivants, la liaison aux clés de cercle et la révocation globale ne satisfont donc pas encore entièrement les invariants 10 et 12.

## Décision humaine

Le propriétaire a accepté l'option A de l'ADR-0005 le 2026-08-25 : une identité Ed25519 au niveau du compte, distincte des clés de chiffrement propres à chaque cercle.
