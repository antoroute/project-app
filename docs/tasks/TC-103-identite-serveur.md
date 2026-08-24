# TC-103 — Dériver l'identité côté serveur

Statut : Terminée
Priorité : P0 sécurité
Décision : mainteneur, avec revue sécurité
Dépendances : TC-102

## Contexte et problème

Le jeton d'accès strict fournit déjà un sujet `sub` vérifié. La majorité des routes l'utilisent, mais l'envoi V2 transmet aussi `sender.userId` dans l'enveloppe signée et l'emploie actuellement comme identité pour l'ACL, la persistance et les événements. Un client authentifié A peut donc tenter de présenter B comme expéditeur. Les routes utilisent en outre des casts `any` répétés qui rendent la provenance de l'identité difficile à auditer.

Les identifiants de destinataires, de membres ciblés et d'appareils ne constituent pas l'identité de l'acteur : ils restent dans les payloads lorsqu'ils sont nécessaires à l'opération et doivent être contrôlés par les ACL.

## Objectif mesurable

- Fournir un accès typé unique à l'identité authentifiée issue de `req.user.sub` après validation du token.
- Utiliser cette identité pour toute décision, écriture et émission attribuée à l'acteur sur REST et Socket.IO.
- Refuser avant ACL et écriture toute enveloppe de message dont `sender.userId` diffère du sujet authentifié, car modifier silencieusement ce champ invaliderait son domaine signé.
- Prouver par test négatif qu'un utilisateur A ne peut ni agir ni persister un message en tant que B.
- Ne pas ajouter de requête réseau, de requête PostgreSQL ou d'étape utilisateur.

## Périmètre

- Routes Auth protégées.
- Routes Messaging REST.
- Envoi de message V2 et événements Socket.IO attribués à l'expéditeur.
- Contrat OpenAPI et smoke test d'usurpation.
- Audit de cohérence du client Flutter existant.

## Hors périmètre

- Refonte et centralisation de toutes les ACL cercle/conversation/rôle (`TC-104`).
- Atomicité des contrôles et écritures (`TC-105`).
- Preuve de possession et cycle de vie des clés d'appareil (`TC-106`).
- Bornes exhaustives et rejet de toute propriété inconnue (`TC-107`).
- Remplacement du protocole cryptographique V2 (`TC-301` et suivants).

## Invariants affectés

- Invariant 1 : l'identité vient exclusivement d'un access token vérifié.
- Invariant 3 : le token est strictement validé avant exposition de son sujet.
- Invariant 6 : les ACL reçoivent l'acteur authentifié, jamais une identité déclarée par le client.
- Invariant 15 : le `sender.userId` signé reste présent dans l'enveloppe et doit correspondre à l'acteur.

## Travail

1. Ajouter un helper typé pour extraire le sujet authentifié dans Auth et Messaging.
2. Remplacer les casts ad hoc dans toutes les routes protégées.
3. Refuser un `sender.userId` divergent avant appel ACL, base ou événement.
4. Passer exclusivement le sujet JWT à l'ACL, à `messages.sender_id` et à l'exclusion de room de l'expéditeur.
5. Ajouter des tests d'intégration de route avec base et Socket.IO factices.
6. Ajouter un scénario négatif au smoke test staging avec deux comptes synthétiques.
7. Aligner OpenAPI, fiche, roadmap et inventaire de staging.

## Critères d'acceptation

- [x] Toute route protégée qui attribue une action à un utilisateur obtient l'identité via le helper commun.
- [x] Aucun identifiant client n'est utilisé comme preuve de l'acteur.
- [x] Une enveloppe A portant `sender.userId=B` reçoit HTTP 403 avant ACL, écriture et émission.
- [x] Une enveloppe valide conserve son identité signée et l'ACL, la base et les rooms reçoivent le sujet JWT.
- [x] Socket.IO continue à dériver son `userId` du token strict et ignore tout identifiant acteur dans les événements entrants.
- [x] Tests et builds Auth/Messaging passent ; le smoke test négatif passe sur LXC106.
- [x] Aucun aller-retour ni délai perceptible n'est ajouté au client.

## Tests et preuves attendues

- Test unitaire du helper avec claims valides et invalides.
- Test par injection Fastify de l'envoi usurpé puis valide avec dépendances factices et assertions sur leurs arguments.
- Recherche statique des accès directs à `req.user.sub` et des identités acteur lues depuis les payloads.
- Suites `npm test`, builds, validation documentaire et smoke test staging.

## Migration et rollback

Aucun schéma ni format d'enveloppe ne change. Les clients honnêtes envoient déjà leur propre identifiant dans le domaine signé ; ils restent compatibles. Seules les enveloppes contradictoires, jusque-là dangereuses, sont refusées. Le rollback applicatif consiste à repointer le staging vers la release Ed25519 de `TC-102` ; aucune donnée ne nécessite de restauration.

## Décisions humaines nécessaires

Aucune pour l'implémentation. Les règles de rôles et d'appartenance seront décidées et centralisées dans `TC-104`.

## Résultat du 2026-08-24

- Commit applicatif déployé sur LXC106 : `8ebeaa30f243a010d22070b8de20d969adedba89`.
- Auth et Messaging exposent chacun un helper typé qui revalide la forme des claims déjà vérifiées puis retourne exclusivement `sub`. Tous les casts directs de `req.user` dans les routes ont été supprimés.
- L'envoi V2 compare le `sender.userId` du domaine signé au sujet JWT. Une divergence retourne HTTP 403 avant appel ACL, insertion PostgreSQL ou émission Socket.IO ; un envoi cohérent passe uniquement le sujet JWT à ces trois frontières.
- Les identifiants de destinataires et de membres ciblés restent des données métier soumises aux ACL, jamais une preuve de l'acteur.
- Le test d'injection Fastify couvre l'usurpation et le chemin légitime avec base, ACL et Socket.IO factices. Les tests unitaires couvrent aussi le helper sur claims valides et invalides.
- `npm ci`, `npm test` et `npm run build` réussissent : 17 tests Auth et 16 tests Messaging. OpenAPI est syntaxiquement valide et les scripts staging passent `bash -n`.
- Le smoke test du staging crée deux comptes synthétiques et prouve que le token de A ne peut pas envoyer une enveloppe déclarant B. Les quatre conteneurs sont sains et étiquetés avec le commit attendu.
- Aucun format client n'a changé. L'audit statique Flutter confirme que l'enveloppe existante utilise déjà l'utilisateur authentifié ; Flutter n'est pas installé sur l'hôte et aucun build client n'a donc été exécuté pour cette tâche.
- Aucun accès réseau ou PostgreSQL supplémentaire n'est ajouté. Dans le conteneur Messaging, 500 000 dérivations ont coûté 0,000125 ms chacune en moyenne.

Risque résiduel : l'identité de l'acteur est maintenant fiable, mais plusieurs routes ne vérifient pas encore correctement l'appartenance, le rôle ou la portée de l'objet. Ces accès croisés sont le périmètre immédiat de `TC-104`, puis leur atomicité relève de `TC-105`.
