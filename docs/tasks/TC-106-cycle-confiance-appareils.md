# TC-106 — Sécuriser le cycle de confiance des appareils

Statut : Terminée — lots A à D validés localement et sur staging
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
- [x] La migration montée/descente et les routes sont validées sur PostgreSQL staging après sauvegarde.
- [x] Les healthchecks, smoke tests et vérifications SQL staging réussissent après déploiement.

## Résultat du lot B

Le registre backend est déployé sur le staging au commit
`6450722344286341da0f9826dc080c35b6dc7f2d`. Auth délivre après comparaison
bcrypt un grant opaque de cinq minutes, stocké uniquement sous forme hachée.
Messaging exige ensuite la preuve Ed25519 sur la transcription binaire V1,
active une seule identité initiale et place les suivantes en attente.

Preuves du 2026-08-25 : 20 tests Auth et 54 tests Messaging réussis ; OpenAPI
et script de smoke validés ; sauvegarde privée
`pre-tc106-20260825T140433Z.dump` vérifiée avec SHA-256
`dd5297a507ddbce9e02cddff305eafbd2a7a53ab336ca9d19188bd24d5dbb01c` ;
restauration isolée, migration montante `3 tables/3 index`, migration
descendante et suppression de la base de test réussies. Le premier smoke test
a détecté une ambiguïté de type PostgreSQL `uuid/text`, corrigée dans le commit
final avant validation. Les quatre conteneurs sont sains sans redémarrage ; le
smoke final couvre bootstrap par mot de passe, signature réelle, rejeu,
appareil suivant `pending`, refus avec access token seul et isolation du
registre. Les contrôles SQL finaux ne relèvent aucune violation de contrainte.

## Critères d'acceptation du lot C

- [x] Une identité Ed25519 de compte/appareil distincte des clés de cercle est créée uniquement lors d'un enrôlement explicite et chargée fail-closed.
- [x] Un auto-login ne génère ni UUID ni clé privée manquants silencieusement.
- [x] Un appareil `pending` ne démarre ni accueil, ni WebSocket, ni conversation, ni publication de clé de cercle.
- [x] Un appareil actif voit nom, plateforme, statut et empreinte courte de la clé complète avant sa décision.
- [x] Approbation et refus utilisent une transcription binaire distincte de 216 octets, documentée et testée par vecteur figé.
- [x] Compte, approbateur, cible, clés, versions, décision, nonce et expiration sont tous liés par Ed25519.
- [x] Signature invalide, rejeu, expiration, changement d'identité, approbateur non actif et autre compte n'activent pas la cible.
- [x] Deux décisions concurrentes ont exactement un gagnant ; un refus signé révoque la cible.
- [x] L'activation ne transfère aucun ancien secret : les paires par cercle sont créées/publiées en arrière-plan uniquement pour les futurs messages.
- [x] Migration montante/descendante, sauvegarde/restauration, smoke réel et cohérence SQL sont validés sur staging.

## Résultat du lot C

Les commits `2877be0951ad6ced0869dfe593872ae6da3f8fb5` et
`0a6e7a0062c0c8fd8ca57f2dd78a15989a4b27a4` implémentent le contrat, les
routes, le client et le smoke reproductible. Le client vérifie les champs
binaires reçus avant toute signature, utilise une barrière d'état
`requiresEnrollment|pending|active|revoked|error` et limite le polling à
l'écran d'attente toutes les huit secondes. La liste d'appareils permet à
l'appareil actif d'approuver ou refuser après confirmation de l'empreinte.

Preuves locales du 2026-08-25 : 20 tests Auth, 65 tests Messaging et 31 tests
Flutter réussis ; analyse Flutter sans erreur ni avertissement bloquant (85
informations historiques) ; bundle OpenAPI généré et `git diff --check`
réussi. Les tests dédiés couvrent vecteur binaire, altérations, rejeu,
expiration, isolation de compte, état approbateur, refus et concurrence.

Preuves staging : sauvegarde privée
`pre-tc106-lotc-20260825T193057Z.dump`, mode `0600`, 46 785 octets, SHA-256
`524b1b463d77d5bba99e884fce7369f067fbacbbae7f911d1185f07f3adc3e89` ;
restauration isolée, montée `1 table/2 index/14 contraintes`, descente et
suppression de la base de test réussies. La release finale est
`0a6e7a0062c0c8fd8ca57f2dd78a15989a4b27a4` : quatre services sains, zéro
redémarrage et zéro log Auth/Messaging `error|fatal`. Le smoke réel couvre
preuve, approbation, rejeu, refus et registre final `active,active,revoked`,
ainsi que les anciens parcours. Les quatre contrôles SQL finaux valent zéro.

## Migration et compatibilité

Le lot A conserve les données locales historiques mais cesse de les sélectionner. Il ne les supprime pas automatiquement : une future migration explicite devra prouver à quel compte elles appartiennent ou les laisser inaccessibles. Cela peut imposer une nouvelle inscription d'appareil aux utilisateurs du prototype, acceptable avant publication et préférable à un rattachement silencieux au mauvais compte.

Les lots B et C utilisent des migrations additives compatibles avec la release
précédente. Le lot D exige une courte fenêtre d'arrêt contrôlée : l'ancienne
route publiait des clés `active` non signées, volontairement refusées par la
nouvelle contrainte. La montée ne supprime aucune donnée et la descente testée
sur copie remet uniquement les anciennes clés `legacy` à leur état `active`
initial, sans réactiver une clé réellement révoquée. Comme toute descente de
fonctionnalité, elle retire toutefois l'historique ajouté par le lot D et les
challenges `revoke` ; elle ne doit donc pas être appliquée sur un environnement
utilisé sans décision explicite sur cette perte et sauvegarde préalable.

## Critères d'acceptation du lot D

- [x] Chaque requête Messaging protégée lie l'access token à un appareil actif par une preuve Ed25519 locale, sans aller-retour réseau supplémentaire.
- [x] Une publication de clé de cercle est signée par l'identité de compte/appareil et lie compte, cercle, appareil, versions, clé Ed25519 et clé X25519.
- [x] Les rotations sont strictement monotones, idempotentes à contenu identique et conservent les versions historiques nécessaires aux anciens messages.
- [x] Chaque enveloppe destinataire indique la version exacte de clé utilisée ; les nouveaux messages exigent les versions actives du destinataire et de l'émetteur.
- [x] Une révocation signée est globale au compte, gagne atomiquement contre publication/rotation et bloque immédiatement HTTP, WebSocket et nouveaux messages.
- [x] Rotation et révocation émettent une invalidation d'annuaire par cercle ; le client purge mémoire et SQLite puis recharge à la prochaine utilisation.
- [x] La perte ou rotation d'une clé courante ne supprime pas les anciennes clés privées locales et les messages historiques restent vérifiables/déchiffrables.
- [x] Les tests locaux couvrent concurrence, rejeu, version manquante, saut de version, clé historique et révocation.
- [x] Migration montante/descendante, sauvegarde/restauration, smoke réel et cohérence SQL validés sur staging.

## Résultat du lot D

Le backend refuse désormais un bearer seul sur les routes Messaging et exige
les trois en-têtes d'appareil signés sur une transcription fixe de 89 octets.
Les clés de cercle sont publiées sur une transcription signée de 152 octets,
versionnées dans un annuaire courant et un historique immuable. La révocation
utilise la décision globale `revoke`, verrouille le registre et les clés dans
une même transaction, puis invalide les annuaires et déconnecte l'appareil
cible après commit.

Le client conserve les anciennes clés privées, inclut la version destinataire
dans chaque wrap et vérifie les signatures historiques avec la version exacte
de l'émetteur. Les invalidations Socket.IO purgent le cercle complet afin de
ne pas conserver un mélange de versions. Ce mécanisme n'ajoute aucun polling
ni appel réseau sur le chemin nominal : la preuve d'accès est calculée
localement à partir du `jti` de l'access token.

Preuves locales du 2026-08-28 : build TypeScript Messaging réussi, 75 tests
Messaging et 38 tests Flutter réussis, analyse Flutter sans erreur bloquante
(85 informations historiques), OpenAPI parsable et `git diff --check` propre.

Preuves staging du 2026-08-28 : sauvegarde privée
`pre-tc106-lotd-20260828T200545Z.dump`, mode `0600`, 55 653 octets et SHA-256
`037f05683ada6b5aec700463ecbc456233e0d0f76a6afc0d68918963f6c95a9b` ;
restauration dans `tc106_lotd_migration_test`, montée, descente exacte vers la
baseline `29 utilisateurs / 11 clés / 2 challenges / 4 messages`, puis
suppression de la base isolée. La migration réelle et la release finale
`9214b0a342cbcfccde4c6ed4fab04ec115d5311b` sont déployées avec quatre
services sains, zéro redémarrage et zéro ligne Auth/Messaging `error|fatal`.

Le smoke a d'abord détecté et fait corriger l'ordre des contraintes du rollback,
puis un écart `200`/`201` de création de conversation désormais couvert par un
test. Le parcours final couvre preuve d'accès, isolation `pending`, décisions
et clés signées, rejeu idempotent, rotation/historique, refus d'une version
obsolète, course révocation/publication et blocage immédiat. Neuf contrôles SQL
finaux valent zéro, notamment les clés actives d'appareils révoqués, les
historiques non monotones et les bases de test résiduelles.

## Décision humaine

Le propriétaire a accepté l'option A de l'ADR-0005 le 2026-08-25 : une identité Ed25519 au niveau du compte, distincte des clés de chiffrement propres à chaque cercle.
