# Protocole de confiance des appareils V1

Statut : contrat du registre, de l'accès, de l'approbation et des clés de cercle, lots B/C/D de `TC-106`
Dernière mise à jour : 2026-08-25
Décision : option A de l'ADR-0005

## Objet

Ce protocole prouve qu'un client contrôle une clé privée Ed25519 propre au couple compte/appareil avant d'inscrire sa clé publique dans le registre de confiance. Cette identité de compte est distincte des paires Ed25519/X25519 utilisées par cercle pour les messages V2.

Il ne constitue ni une attestation matérielle de la plateforme, ni une récupération de compte, ni le protocole E2EE V3. Le serveur ne reçoit jamais la clé privée.

## Identité et états

Chaque compte utilisé sur une installation possède :

- un `deviceId` UUID propre au compte ;
- une paire Ed25519 d'identité d'appareil, version 1 ;
- un nom d'affichage et une plateforme parmi `android|ios|windows|macos|unknown` ;
- un état serveur `pending|active|revoked`.

Le premier appareil **prouvé et réautorisé par mot de passe** d'un compte sans aucun historique d'activation devient `active`. Dès qu'une ligne du compte possède ou a possédé `activated_at`, aucun autre bootstrap n'est possible, même si tous les appareils actifs sont ensuite révoqués. Les appareils suivants restent `pending` jusqu'à une décision signée par un appareil `active` du même compte.

## Autorisation initiale de bootstrap

Un access token seul ne permet pas d'activer le premier appareil. Après vérification de l'access token, Auth exige à nouveau le mot de passe sur :

```http
POST /auth/device-bootstrap-grant
```

Auth retourne 32 octets CSPRNG encodés en Base64URL sans padding, valables 5 minutes. PostgreSQL ne conserve que `SHA-256(ASCII(grant))`, jamais le grant brut. La route est limitée à 5 appels par adresse et la création à 5 grants par compte sur 10 minutes.

Le client peut demander cette autorisation immédiatement après un login par mot de passe avec la valeur qu'il possède déjà ; aucun second écran n'est alors nécessaire. Lors d'un auto-login sans appareil initial, une nouvelle saisie du mot de passe est requise.

## Création du challenge

Requête authentifiée :

```http
POST /api/devices/registrations/challenge
```

Le client fournit `deviceId`, `identityPublicKey = Base64(clé Ed25519 brute de 32 octets)`, `platform`, `deviceName` et, pour le premier appareil, le `bootstrapGrant`. Les encodages doivent être canoniques. Messaging ne stocke dans le challenge que la référence au grant haché validé.

Le serveur génère avec le CSPRNG de Node.js :

- `challengeId` : UUID v4 ;
- `challengeNonce` : 32 octets ;
- `expiresAt` : heure serveur + 300 secondes.

La réponse contient le nonce et surtout `transcript`, les octets exacts que le client doit signer. Le client ne reconstruit pas librement une représentation JSON.

## Transcription binaire signée

Longueur totale V1 : **163 octets**.

| Offset | Taille | Valeur |
|---:|---:|---|
| 0 | 43 | ASCII `circlehaven/account-device-registration/v1` suivi de `00` |
| 43 | 16 | UUID du challenge, octets réseau après retrait des tirets |
| 59 | 16 | UUID du sujet JWT |
| 75 | 16 | UUID de l'appareil |
| 91 | 32 | clé publique Ed25519 brute |
| 123 | 32 | nonce aléatoire du challenge |
| 155 | 8 | expiration Unix en secondes, entier non signé big-endian |

La signature transmise est :

```text
signature = Ed25519.sign(deviceIdentityPrivateKey, transcript)
```

Elle fait 64 octets et est envoyée en Base64 canonique à :

```http
POST /api/devices/registrations/{challengeId}/proof
```

### Vecteur de transcription

Entrées :

- challenge : `11111111-1111-4111-8111-111111111111` ;
- compte : `22222222-2222-4222-8222-222222222222` ;
- appareil : `33333333-3333-4333-8333-333333333333` ;
- clé publique : octets `00` à `1f` ;
- nonce : octets `a0` à `bf` ;
- expiration : `2000000000`.

Transcription Base64 :

```text
Y2lyY2xlaGF2ZW4vYWNjb3VudC1kZXZpY2UtcmVnaXN0cmF0aW9uL3YxABEREREREUERgREREREREREiIiIiIiJCIoIiIiIiIiIiMzMzMzMzQzODMzMzMzMzMwABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4foKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr8AAAAAdzWUAA==
```

Ce vecteur est figé dans `backend/messaging/test/device-proof-crypto.test.mjs`.

## Approbation ou refus par un appareil actif

L'approbation utilise un domaine et une transcription distincts de la preuve de
possession. Un appareil `pending` ne peut ni approuver ni refuser un autre
appareil. L'appareil actif choisit explicitement une décision `approve`,
`reject` ou `revoke`, puis demande :

```http
POST /api/devices/{targetDeviceId}/approvals/challenge
```

avec son propre `approverDeviceId` et la décision. Le serveur relit et fige dans
le challenge les deux clés publiques et leurs versions. Le client affiche le nom,
la plateforme et une empreinte courte de la clé cible avant confirmation, mais
l'empreinte n'est qu'une aide visuelle : la signature porte sur la clé complète.

### Transcription binaire d'approbation V1

Longueur totale : **216 octets**.

| Offset | Taille | Valeur |
|---:|---:|---|
| 0 | 39 | ASCII `circlehaven/account-device-approval/v1` suivi de `00` |
| 39 | 16 | UUID du challenge, octets réseau après retrait des tirets |
| 55 | 16 | UUID du sujet JWT |
| 71 | 16 | UUID de l'appareil approbateur |
| 87 | 4 | version de sa clé d'identité, entier non signé big-endian |
| 91 | 32 | sa clé publique Ed25519 brute |
| 123 | 16 | UUID de l'appareil cible |
| 139 | 4 | version de la clé d'identité cible, entier non signé big-endian |
| 143 | 32 | clé publique Ed25519 brute de la cible |
| 175 | 1 | décision : `01` pour approuver, `02` pour refuser, `03` pour révoquer un appareil actif |
| 176 | 32 | nonce aléatoire du challenge |
| 208 | 8 | expiration Unix en secondes, entier non signé big-endian |

L'appareil actif signe exactement le champ `transcript` Base64 retourné par le
serveur, sans le reconstruire depuis du JSON, puis transmet la signature Ed25519
de 64 octets en Base64 canonique à :

```http
POST /api/devices/approvals/{challengeId}/decision
```

Une approbation valide fait passer la cible de `pending` à `active`. Un refus
valide la fait passer de `pending` à `revoked`; le même identifiant ne peut alors
pas être réinscrit silencieusement. Une révocation valide fait passer une cible
`active` à `revoked` et désactive dans la même transaction toutes ses clés de
cercle courantes.

### Vecteur d'approbation

Entrées : challenge `11111111-1111-4111-8111-111111111111`, compte
`22222222-2222-4222-8222-222222222222`, approbateur
`33333333-3333-4333-8333-333333333333` version 7 avec clé `00` à `1f`, cible
`44444444-4444-4444-8444-444444444444` version 9 avec clé `20` à `3f`, décision
`approve`, nonce `a0` à `bf` et expiration `2000000000`.

```text
Y2lyY2xlaGF2ZW4vYWNjb3VudC1kZXZpY2UtYXBwcm92YWwvdjEAERERERERQRGBERERERERESIiIiIiIkIigiIiIiIiIiIzMzMzMzNDM4MzMzMzMzMzAAAABwABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fRERERERERESERERERERERAAAAAkgISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+PwGgoaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+vwAAAAB3NZQA
```

Ce vecteur est figé dans
`backend/messaging/test/device-approval-crypto.test.mjs`.

### Concurrence et consommation des décisions

- le challenge expire après 5 minutes et une signature bien encodée, valide ou
  non, le consomme ;
- compte, deux appareils, deux clés et versions, décision, nonce et expiration
  sont tous authentifiés par la signature ;
- le serveur revalide sous verrou que l'approbateur est toujours `active`, que
  sa clé n'a pas changé et que la cible possède encore la même clé ; la cible
  doit être `pending` pour `approve|reject` et `active` pour `revoke` ;
- les transitions sont `SERIALIZABLE` et verrouillent la ligne du compte : deux
  décisions concurrentes ont un seul gagnant ;
- la décision gagnante rend tous les autres challenges ouverts pour la même
  cible caducs ;
- les mêmes bornes anti-abus s'appliquent : 8 challenges ouverts, 20 créations
  par compte et 6 par cible sur 10 minutes.

L'activation ne transfère aucun secret ni message historique. Le nouvel appareil
publie ensuite de nouvelles clés propres à chacun de ses cercles et ne devient
destinataire que des futurs messages.

## Consommation, concurrence et anti-abus

- Un challenge expire après 5 minutes.
- La première preuve cryptographique correctement encodée le consomme, que la signature soit valide ou non.
- Un nouveau challenge du même compte/appareil invalide le précédent.
- Le challenge est lié au sujet JWT ; un autre compte reçoit `404` et ne le consomme pas.
- Les transitions utilisent une transaction `SERIALIZABLE` et verrouillent d'abord la ligne `users` du compte. Deux preuves de premier appareil concurrentes produisent donc exactement un `active` et un `pending`.
- Si aucun appareil n'a jamais été actif, la preuve consomme atomiquement un grant Auth non expiré. Sans grant, avec un grant faux, expiré ou déjà consommé, aucun bootstrap n'est possible.
- Limites : 8 challenges non expirés pour des appareils distincts, 20 créations par compte et 6 par appareil sur 10 minutes.
- Les challenges consommés ou expirés depuis plus de 7 jours sont supprimés opportunément à la prochaine création du même compte.

## Propriétés obtenues

- Un access token volé ne suffit pas à activer une clé choisie par l'attaquant comme premier appareil : il manque la réauthentification par mot de passe.
- Le grant de bootstrap volé sans la clé privée annoncée ne suffit pas non plus : la preuve Ed25519 reste obligatoire.
- Compte, appareil, clé, nonce et expiration sont liés par la signature.
- Une preuve ne peut pas être rejouée ou transférée vers un autre compte/appareil/clé.
- La clé publique identique ne peut pas être associée à deux appareils d'un même compte.
- Un identifiant d'appareil déjà révoqué ne peut pas être réinscrit par ce parcours.

## Preuve d'accès liée à chaque access token

Après enrôlement, un bearer token ne suffit plus à utiliser Messaging. Chaque
requête protégée et chaque handshake Socket.IO présente également :

```http
X-CircleHaven-Device-Id: <uuid>
X-CircleHaven-Device-Key-Version: <entier>
X-CircleHaven-Device-Proof: <Base64 signature Ed25519 64 octets>
```

La signature est recalculée localement quand le `jti` de l'access token change.
Elle n'ajoute aucun aller-retour réseau et sa vérification locale mesurée reste
très inférieure à une milliseconde sur le backend de test. La transcription fait
exactement **89 octets** :

| Offset | Taille | Valeur |
|---:|---:|---|
| 0 | 37 | ASCII `circlehaven/account-device-access/v1` suivi de `00` |
| 37 | 16 | UUID du sujet JWT |
| 53 | 16 | UUID de l'appareil |
| 69 | 4 | version de la clé d'identité, entier non signé big-endian |
| 73 | 16 | UUID `jti` de l'access token |

Vecteur figé pour le compte `11111111-1111-4111-8111-111111111111`,
l'appareil `22222222-2222-4222-8222-222222222222`, la version `7` et le `jti`
`33333333-3333-4333-8333-333333333333` :

```text
Y2lyY2xlaGF2ZW4vYWNjb3VudC1kZXZpY2UtYWNjZXNzL3YxABEREREREUERgREREREREREiIiIiIiJCIoIiIiIiIiIiAAAABzMzMzMzM0MzgzMzMzMzMzM=
```

Le serveur relit `account_devices` à chaque autorisation. `pending` et `revoked`
ne peuvent donc ni ouvrir un WebSocket, ni lire/écrire des données métier, ni
publier une clé. L'exception volontaire concerne les deux routes d'enrôlement,
car un appareil encore inconnu ne peut pas produire une preuve reconnue. La
liste `/api/devices` accepte une identité reconnue non active mais ne lui révèle
que sa propre ligne, afin que l'écran d'attente puisse évoluer sans polling
agressif.

## Liaison signée des clés de cercle

Une clé Ed25519/X25519 de cercle n'est active que si l'appareil `active` signe
son rattachement avec sa clé d'identité de compte. La transcription fait
exactement **152 octets** :

| Offset | Taille | Valeur |
|---:|---:|---|
| 0 | 32 | ASCII `circlehaven/group-device-key/v1` suivi de `00` |
| 32 | 16 | UUID du compte |
| 48 | 16 | UUID du cercle |
| 64 | 16 | UUID de l'appareil |
| 80 | 4 | version de la clé d'identité |
| 84 | 4 | version de la paire du cercle |
| 88 | 32 | clé publique Ed25519 brute `pk_sig` |
| 120 | 32 | clé publique X25519 brute `pk_kem` |

Vecteur figé : compte `11111111-1111-4111-8111-111111111111`, cercle
`22222222-2222-4222-8222-222222222222`, appareil
`33333333-3333-4333-8333-333333333333`, versions d'identité `7` et de clé `9`,
`pk_sig = 00..1f`, `pk_kem = 20..3f` :

```text
Y2lyY2xlaGF2ZW4vZ3JvdXAtZGV2aWNlLWtleS92MQARERERERFBEYERERERERERIiIiIiIiQiKCIiIiIiIiIjMzMzMzM0MzgzMzMzMzMzMAAAAHAAAACQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=
```

Le serveur vérifie simultanément le bearer, la preuve d'accès, l'appartenance
au cercle, l'état courant du registre, la version d'identité et cette signature.
Les anciennes publications du prototype sont marquées `legacy` par la migration
et exclues de l'annuaire tant qu'elles ne sont pas republiées avec une liaison
valide.

## Rotation versionnée et historique

- La première publication signée porte obligatoirement la version `1`.
- Une republication identique de la version courante est idempotente.
- La même version avec d'autres octets est un conflit, et une version ancienne
  ou un saut de version est refusé.
- Une rotation valide accepte uniquement `current + 1`. La version courante est
  copiée dans `group_device_key_history` avec l'état `superseded`, puis la
  nouvelle devient `active`, dans une transaction `SERIALIZABLE`.
- Le client conserve chaque seed privé historique sous un nom contenant sa
  version. Il signe les nouveaux messages avec la version courante, mais choisit
  la version X25519 destinataire inscrite dans chaque ancien wrap pour relire
  l'historique.
- Le backend exige la version courante pour tout nouvel expéditeur et tout
  destinataire. Les états `superseded|revoked` restent retournés uniquement pour
  vérifier ou déchiffrer des messages déjà persistés.

## Révocation et propagation déterministe

La décision `revoke` verrouille le compte, revalide les deux identités, passe la
cible à `account_devices.revoked` et toutes ses lignes courantes
`group_device_keys` à `revoked` dans une seule transaction. Après le commit :

1. `device:revoked` informe les autres appareils du compte des cercles affectés ;
2. les sockets du terminal cible sont déconnectés ;
3. `device:key-directory-changed` est envoyé dans chaque room de cercle ;
4. les clients retirent immédiatement de la mémoire l'annuaire complet du seul
   cercle concerné et suppriment sa copie SQLite ;
5. le prochain besoin recharge une vue unique contenant nouvelle version et
   historique signé.

L'invalidation porte sur l'annuaire complet, pas uniquement sur l'appareil :
cela empêche un cache de continuer à sélectionner une clé révoquée tout en
préservant l'accès aux versions historiques lors du rechargement. Il n'existe ni
polling supplémentaire, ni délai fixe sur le chargement normal des messages.
Même si un événement temps réel est perdu, chaque nouvelle requête REST et tout
nouvel envoi sont refusés côté serveur dès le commit de révocation.

## Limites connues

- La révocation ne retire pas les messages, clés de message ou contenus déjà
  reçus avant la décision ; aucune E2EE ne peut reprendre une copie déjà livrée.
- La rotation V2 conserve les anciennes clés privées pour l'historique et ne
  fournit donc pas à elle seule la forward secrecy ou la post-compromise
  security ; ces propriétés relèvent du protocole V3.
- Socket.IO et les événements d'invalidation sont actuellement locaux à une
  instance Messaging. Un déploiement multi-instance devra ajouter un adaptateur
  de diffusion partagé avant mise à l'échelle.
- L'identité d'appareil reste une clé applicative dans le stockage sécurisé de
  l'OS, sans attestation matérielle du constructeur.
