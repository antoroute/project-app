# TC-107 — Borner et valider toutes les entrées réseau

Statut : Terminée — validée localement et sur staging le 2026-09-08
Priorité : P0 sécurité et disponibilité
Décision : mainteneur, dans le cadre des invariants existants
Dépendances : TC-103, TC-106

## Contexte et problème

Les routes utilisent déjà TypeBox de manière partielle, mais plusieurs objets
acceptent encore des propriétés inconnues et certains champs n'ont aucune
borne maximale effective. `contentEncoding: base64` documente l'intention sans
garantir à lui seul la canonicité ni la taille décodée. Les événements
Socket.IO utilisent des objets `any`, les tableaux batch ne sont pas plafonnés
et le curseur de messages mélange actuellement secondes et millisecondes.

Une entrée non bornée peut consommer inutilement mémoire, CPU, base de données
ou journaux avant que l'autorisation ne la rejette. Une validation ambiguë
augmente aussi le risque que Flutter, OpenAPI et le serveur interprètent
différemment le même payload.

## Objectif mesurable

- Refuser avant accès métier toute structure, propriété, taille ou encodage
  hors contrat avec une réponse déterministe.
- Appliquer des limites globales et par champ qui restent largement au-dessus
  des besoins V1 normaux.
- Valider les événements Socket.IO sans requête SQL pour un payload invalide.
- Aligner serveur, Flutter, smoke staging et OpenAPI sur les mêmes unités et
  limites.

## Limites retenues pour la V1

| Surface | Limite |
|---|---:|
| Corps JSON Auth | 16 Kio |
| Corps JSON Messaging | 256 Kio |
| E-mail | 254 caractères |
| Nom d'utilisateur / appareil / cercle | 64 caractères |
| Mot de passe reçu | 1 024 caractères |
| Participants d'une conversation | 128 UUID uniques |
| Destinataires d'un message | 256 couples compte/appareil uniques |
| Contenu chiffré d'un message | 64 Kio décodés, tag inclus |
| Abonnement Socket.IO batch | 100 UUID uniques |
| Payload Socket.IO | 16 Kio |
| Pagination de messages | 1 à 100 éléments, défaut 50 |

Les clés, signatures, nonces, sels et wraps utilisent leur taille
cryptographique exacte et un Base64 RFC 4648 canonique avec padding. Les UUID
sont ceux acceptés par le format TypeBox/Fastify et les versions de clé sont
des entiers non signés sur 32 bits hors zéro.

## Découpage

### Lot A — Socle et Auth

- Configurer explicitement les limites de corps Fastify.
- Fermer les objets JSON aux propriétés inconnues.
- Borner e-mail, nom d'utilisateur et mot de passe sans journaliser leur valeur.
- Ajouter des tests 400/413 et vérifier qu'aucun hash ni accès DB n'a lieu.

### Lot B — REST Messaging

- Centraliser les schémas de UUID, texte et Base64 canonique.
- Borner tous les tableaux, clés, signatures, enveloppes et champs chiffrés.
- Refuser doublons de membres/destinataires avant écriture.
- Corriger le curseur Unix en secondes et plafonner la page à 100.

### Lot C — Socket.IO

- Valider strictement `conv:subscribe`, `conv:subscribe:batch`,
  `conv:unsubscribe` et `typing:start|stop`.
- Refuser type inattendu, propriété inconnue, UUID invalide, doublon ou batch
  trop grand avant ACL/room.
- Fixer `maxHttpBufferSize` sans dégrader les messages, qui passent par REST.

### Lot D — Contrat et staging

- Ajouter une matrice de tests négatifs et de valeurs frontières.
- Aligner OpenAPI et les validations simples Flutter.
- Exécuter builds, tests, analyse statique, smoke et probes de surcharge sur
  `trust-circle-staging`, après sauvegarde si une migration devenait nécessaire.

## Critères d'acceptation

- [x] Tous les objets d'entrée déclarés sont fermés aux propriétés inconnues.
- [x] Toute chaîne, liste et donnée binaire contrôlée possède une limite.
- [x] Les tailles binaires exactes sont vérifiées après décodage canonique.
- [x] Aucun tableau de membres, destinataires ou abonnements ne contient de
      doublon ou ne dépasse sa borne.
- [x] Le curseur émis par le serveur est relu dans la même unité.
- [x] Un événement WebSocket invalide n'appelle ni ACL, ni base, ni room.
- [x] Les dépassements globaux répondent `413` sans fuite de contenu.
- [x] Flutter bloque localement les dépassements visibles et affiche une erreur
      compréhensible, tout en laissant le serveur autoritaire.
- [x] OpenAPI décrit les mêmes contraintes que le code.
- [x] Tests locaux et smoke/probes staging réussissent sans régression.

## Preuves de clôture

- Commit applicatif immuable :
  `9ffc84f36e47aee5d86eb03f14307c93f5ef02dd`.
- Auth : build TypeScript et 23 tests réussis.
- Messaging : build TypeScript et 81 tests réussis.
- Flutter 3.47.1 : 38 tests réussis ; analyse sans erreur ni avertissement,
  avec 85 informations de style historiques.
- OpenAPI 3.1 analysé sans erreur ni clé YAML dupliquée.
- Staging LXC106 : quatre services sains, zéro redémarrage, labels alignés sur
  le commit et aucun log Auth/Messaging de niveau erreur ou fatal après le
  déploiement.
- Smoke réel : transitions TC-106 intactes, propriétés inconnues refusées,
  limites de corps Auth/Messaging en `413`, doublons et page hors borne en
  `400`, taille décodée du chiffré refusée au-delà de 64 Kio.
- Aucune migration ni modification du schéma : aucune sauvegarde PostgreSQL
  supplémentaire n'était requise. Le rollback applicatif reste la release
  `9214b0a342cbcfccde4c6ed4fab04ec115d5311b`.

## Risques et hors périmètre

- Les politiques CORS, `trustProxy`, quotas par IP/compte et rate limits fins
  relèvent de `TC-108`.
- La taille maximale future des pièces jointes ne doit pas réutiliser celle des
  messages texte ; les fichiers sont hors V1.
- La sémantique d'horloge et l'ordre durable des messages relèvent de `TC-501` ;
  TC-107 borne uniquement la représentation numérique et corrige l'unité du
  curseur existant.
- Les anciennes routes de jointure restent compatibles mais leurs champs
  hérités deviennent strictement bornés.

## Invariants affectés

- Invariants 1, 6 et 9 : identité/autorisation avant effet métier sans oracle.
- Invariants 14 à 18 : matériel cryptographique et enveloppes stricts.
- Invariants 21 et 22 : identifiants et curseurs déterministes.
- Invariant 30 : documentation conforme au comportement livré.
