# ADR-0005 — Ancrage de confiance des appareils

Statut : Acceptée — option A
Date : 2026-08-25
Décision propriétaire : 2026-08-25
Tâche : `TC-106`

## Contexte

CircleHaven utilise aujourd'hui une paire Ed25519/X25519 différente par cercle et appareil. Ce modèle permet l'enveloppement des clés de message, mais il ne fournit aucune identité stable au niveau du compte pour approuver un nouvel appareil. Une approbation indépendante dans chaque cercle serait longue et difficile à comprendre, particulièrement pour le parcours téléphone vers Windows visé en V1.

Cette décision concerne uniquement l'enrôlement et le statut de confiance des appareils. Elle ne choisit ni ne modifie le futur protocole de messages V3 couvert par l'ADR-0003.

## Option A — Identité d'appareil au niveau du compte (recommandée)

Chaque installation et compte possède une clé Ed25519 d'identité d'appareil. Sa clé privée reste dans le stockage sécurisé local. Le serveur conserve la clé publique et un état `pending|active|revoked`.

- Le nouvel appareil prouve la possession de sa clé sur un challenge serveur aléatoire, expirant et à usage unique.
- Le premier appareil d'un compte peut être activé par un bootstrap explicitement borné.
- Tout appareil suivant est approuvé par la signature d'un appareil déjà actif du même compte.
- Après activation, l'appareil publie ses clés de chiffrement propres à chaque cercle ; il ne reçoit aucun ancien secret.
- Une révocation du registre de compte désactive transactionnellement toutes les clés de cercle de cet appareil.

Avantages : une seule approbation compréhensible, séparation nette identité de compte/clés de cercle, preuve et révocation testables, compatible avec Android/iOS/Windows sans attestation propriétaire.

Risques : nouvelle table et nouveaux parcours ; le bootstrap et la récupération totale doivent être strictement séparés ; le serveur voit toujours les métadonnées d'appareils.

## Option B — Approbation indépendante dans chaque cercle

Chaque paire Ed25519/X25519 de cercle est prouvée puis approuvée par un appareil déjà actif dans ce cercle.

Avantage : pas de nouvelle identité cryptographique de compte.

Risques : une approbation par cercle, expérience très lourde, états divergents et révocation globale difficile. Cette option est déconseillée pour la V1 grand public.

## Option C — Reporter toute approbation au protocole V3

Le comportement actuel est conservé jusqu'au choix MLS/autre de `TC-301`.

Avantage : aucune construction intermédiaire.

Risques : les invariants 10 à 12 restent ouverts pendant toute la Phase 1 et une clé peut toujours être substituée/enregistrée avec un simple access token. Cette option bloque la fermeture de sécurité et la bêta.

## Décision

L'option A est retenue. Les signatures utilisent des transcriptions binaires
versionnées et préfixées par des domaines distincts. Les formats de preuve de
possession du lot B, d'approbation du lot C, de preuve d'accès et de liaison des
clés de cercle du lot D sont figés avec leurs vecteurs dans
[`DEVICE_TRUST_PROTOCOL_V1.md`](../security/DEVICE_TRUST_PROTOCOL_V1.md).

Le bootstrap du premier appareil ne constitue pas une récupération. Si un appareil actif a déjà existé puis a été perdu/révoqué, seul le parcours renforcé de récupération peut créer une nouvelle identité.

## Conséquences

- Ajout d'un registre d'appareils au niveau du compte et de challenges à durée courte.
- Ajout d'une clé locale distincte des clés Ed25519/X25519 par cercle.
- Aucune clé privée ni ancien secret de message ne transite par le serveur.
- L'interface affiche clairement appareil en attente, appareil actif et appareil révoqué.
- Une décision ultérieure MLS/V3 pourra rattacher ses credentials à cette identité ou fournir une migration explicite ; elle ne devra pas réutiliser silencieusement les formats de preuve V1.
- Toute route Messaging métier et tout handshake Socket.IO exigent une preuve
  Ed25519 liée au `jti` de l'access token, sans requête réseau supplémentaire.
- Les versions de clé de cercle sont monotones ; les anciennes versions restent
  immuables pour l'historique mais sont interdites pour tout nouvel envoi.
- Rotation et révocation émettent un événement minimal d'invalidation après
  commit ; le serveur reste l'autorité même si cet événement est perdu.
