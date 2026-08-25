# Protocole de confiance des appareils V1

Statut : contrat du registre backend et de l'approbation, lots B/C de `TC-106`
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
appareil. L'appareil actif choisit explicitement une décision `approve` ou
`reject`, puis demande :

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
| 175 | 1 | décision : `01` pour approuver, `02` pour refuser |
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
pas être réinscrit silencieusement.

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
  sa clé n'a pas changé et que la cible est toujours `pending` avec la même clé ;
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

## Limites temporaires

Le lot C fournit l'approbation signée, mais la liaison obligatoire des
publications `group_device_keys` au statut du registre et la révocation globale
relèvent du lot D. Ce choix expand/contract maintient la compatibilité du
prototype pendant le développement du client. Il ne faut donc pas considérer
les invariants 10 et 12 entièrement fermés avant ce lot.

La preuve n'ajoute aucun aller-retour au chargement des conversations ou des messages : elle est exécutée uniquement lors de l'enrôlement d'un appareil.
