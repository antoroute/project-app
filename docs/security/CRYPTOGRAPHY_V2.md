# Spécification du chiffrement V2 observé

Statut : description du code existant, **pas** spécification d'un protocole approuvé
Dernière mise à jour : 2026-08-25
Code observé : branche `main`, changement `TC-106` lot D
Implémentation principale : `lib/core/crypto/message_cipher_v2.dart`

## Objet

Ce document décrit précisément le chiffrement de bout en bout actuellement implémenté par CircleHaven — Trust Circle. Il distingue :

- ce que fait réellement le client ;
- les propriétés que ce mécanisme apporte ;
- les limites et vulnérabilités connues ;
- la cible de remplacement définie par l'ADR-0003.

Les exigences normatives restent celles de [`SECURITY_INVARIANTS.md`](SECURITY_INVARIANTS.md). En cas de contradiction, un comportement décrit ici est un écart à corriger, pas une nouvelle règle.

## Périmètre de confiance

Le chiffrement V2 est exécuté dans le client Flutter. Dans le scénario nominal :

- la clé privée X25519 d'un appareil sert à ouvrir les clés de message qui lui sont destinées ;
- la clé privée Ed25519 de l'expéditeur signe l'enveloppe ;
- le backend relaie et conserve enveloppes, signatures et métadonnées ;
- le backend ne reçoit ni texte clair, ni clé de message, ni clé privée E2EE.

Cette description ne protège pas contre un client compromis, un appareil déverrouillé, une substitution de clé dans l'annuaire actuel ou une fuite du texte clair après déchiffrement.

## Primitives et formats

| Usage | Primitive observée | Paramètres |
|---|---|---|
| identité de confiance compte/appareil | Ed25519 | graine privée 32 octets, une paire par compte local |
| signature E2EE d'appareil par cercle | Ed25519 | graine privée 32 octets, une paire par cercle/appareil |
| échange de secret | X25519 | clé statique du destinataire, clé éphémère par message |
| dérivation | HKDF-SHA-256 | sortie 32 octets, sel propre au message |
| chiffrement du contenu | AES-256-GCM | clé 32 octets, nonce 12 octets, tag 16 octets |
| encapsulation de la clé de message | AES-256-GCM | clé dérivée 32 octets, nonce 12 octets, tag 16 octets |
| empreinte de contenu signé | SHA-256 | hexadécimal minuscule du texte Base64 du chiffré |
| encodage binaire | Base64 | représentation JSON des clés, nonces et chiffrés |

Les appels aléatoires du chiffrement des messages et la clé maître du cache de clés de message utilisent `Random.secure()`.

## Clés et secrets

### Identifiant d'appareil local par compte

`SessionDeviceService` valide l'UUID du sujet authentifié puis crée un UUID sous `device_id_v2:account:<userId>` dans `flutter_secure_storage`. La mémoire est également indexée par compte et purgée à la déconnexion ou au changement de sujet.

L'ancien `device_id_v1`, global à l'installation, n'est ni lu ni migré automatiquement : son rattachement à un compte ne peut pas être démontré. Chaque compte utilisé sur une installation reçoit ainsi son propre identifiant local.

`AccountDeviceIdentityService` conserve séparément une graine et une clé publique Ed25519 sous `account_device_identity_v1:account:<userId>:ed25519_seed|ed25519_public`. Cette identité de confiance n'est pas une paire E2EE de cercle. Sa création est réservée à l'enrôlement explicite ; un auto-login charge le matériel existant et échoue si celui-ci est absent, partiel, mal encodé, d'une taille autre que 32 octets ou si la clé publique ne correspond pas à la graine.

Les lots B/C/D de `TC-106` enregistrent la clé publique après preuve de
possession, lient les décisions d'appareil à une seconde transcription, exigent
une preuve d'accès liée au `jti` et font signer chaque publication de clé de
cercle. Les formats exacts, domaines, tailles et vecteurs sont spécifiés dans
[`DEVICE_TRUST_PROTOCOL_V1.md`](DEVICE_TRUST_PROTOCOL_V1.md).

### Paires de clés E2EE

Pour chaque couple `(groupId, deviceId)`, `KeyManagerFinal` génère et conserve :

- une graine privée Ed25519 de 32 octets et sa clé publique ;
- une graine privée X25519 de 32 octets et sa clé publique.

Clés de stockage sécurisé observées :

```text
v2:<groupId>:<deviceId>:ed25519:seed
v2:<groupId>:<deviceId>:ed25519_pub:seed
v2:<groupId>:<deviceId>:x25519:seed
v2:<groupId>:<deviceId>:x25519_pub:seed
```

La version 1 conserve ces noms pour ne pas perdre l'historique. À partir de la
version 2, le segment `:v<version>:` est ajouté avant le type de clé, et
`v2:<groupId>:<deviceId>:current_key_version` sélectionne la version courante.
Une rotation n'écrase ni ne supprime aucun seed précédent.

Le suffixe `:seed` est également appliqué aux clés publiques ; il s'agit d'une convention d'implémentation, pas d'une propriété cryptographique.

Les paires sont mises en cache en mémoire sous la clé `<groupId>:<deviceId>`. Le `deviceId` est désormais propre au compte. Une création n'est permise que par l'appel explicite `ensureKeysFor` lorsque les quatre valeurs sont absentes. Les méthodes de lecture, signature et déchiffrement ne génèrent rien : une valeur manquante, partielle, Base64 invalide, d'une taille autre que 32 octets ou dont la clé publique ne correspond pas au seed provoque une erreur fail-closed sans suppression ni réécriture. Deux créations concurrentes du même couple sont sérialisées.

### Publication et annuaire

Le client signe compte, cercle, appareil, versions et deux clés publiques avec
son identité Ed25519 de compte avant de publier dans `group_device_keys`. Le
backend accepte seulement la première version `1`, un rejeu identique ou la
version immédiatement suivante. La version remplacée devient immuable dans
`group_device_key_history`. Les autres clients récupèrent versions courantes et
historiques dans le même annuaire.

L'empreinte locale actuelle détecte surtout une altération accidentelle de la réponse mise en cache. Elle ne constitue ni une preuve d'identité, ni un journal de transparence, ni une approbation préalable de la clé. Un serveur contrôlant l'annuaire peut donc substituer une clé publique sans mécanisme de détection robuste côté utilisateur.

La révocation globale empêche l'usage futur d'une entrée côté serveur, coupe le
WebSocket cible et invalide l'annuaire du cercle chez les clients connectés. Elle
n'efface pas les secrets ou enveloppes déjà obtenus.

### Clé de message

Chaque message reçoit une clé aléatoire `MK` de 32 octets. Une copie chiffrée de `MK` est produite pour chaque appareil destinataire. Le serveur ne reçoit que ces copies encapsulées.

## Construction d'une enveloppe

### 1. Valeurs propres au message

Le client crée :

- `messageId` : UUID ;
- `sentAt` : secondes Unix ;
- `MK` : 32 octets aléatoires ;
- `contentNonce` : 12 octets aléatoires ;
- une paire X25519 éphémère unique au message ;
- `salt = SHA-256(UTF8(messageId + ":" + Base64(random16)))`.

Le sel lie le champ `messageId` à 16 octets aléatoires supplémentaires. Il ne peut pas être recalculé à partir du seul `messageId` et est donc transporté dans l'enveloppe.

### 2. Chiffrement du texte

```text
content = UTF8(plaintext)
ciphertext, tag = AES-256-GCM.encrypt(MK, contentNonce, content)
payload.ciphertext = Base64(ciphertext || tag)
payload.iv = Base64(contentNonce)
```

Aucune donnée associée authentifiée (AAD) n'est fournie à AES-GCM. Les métadonnées ne sont liées au contenu que par la signature décrite plus bas.

### 3. Encapsulation pour chaque appareil

Pour chaque entrée destinataire
`(userId, deviceId, recipientKeyVersion, recipientX25519PublicKey)` :

```text
sharedSecret = X25519(ephemeralPrivateKey, recipientX25519PublicKey)
info = UTF8("project-app/v2 <groupId> <convId> <userId> <deviceId>")
KEK = HKDF-SHA-256(sharedSecret, salt, info, 32)
wrapNonce = random(12)
wrapped, tag = AES-256-GCM.encrypt(KEK, wrapNonce, MK)
recipient.wrap = Base64(wrapped || tag)
recipient.nonce = Base64(wrapNonce)
recipient.key_version = recipientKeyVersion
```

Une seule clé X25519 éphémère est utilisée pour toutes les encapsulations du message. La clé publique éphémère se trouve dans `sender.eph_pub`.

### 4. Structure JSON utile

```json
{
  "v": 2,
  "alg": {
    "kem": "X25519",
    "kdf": "HKDF-SHA256",
    "aead": "AES-256-GCM",
    "sig": "Ed25519"
  },
  "groupId": "...",
  "convId": "...",
  "messageId": "...",
  "sentAt": 0,
  "sender": {
    "userId": "...",
    "deviceId": "...",
    "eph_pub": "base64",
    "key_version": 1
  },
  "recipients": [
    {
      "userId": "...",
      "deviceId": "...",
      "key_version": 1,
      "wrap": "base64(ciphertext || tag)",
      "nonce": "base64"
    }
  ],
  "iv": "base64",
  "ciphertext": "base64(ciphertext || tag)",
  "salt": "base64",
  "sig": "base64"
}
```

## Signature observée

Le code ne signe pas une sérialisation JSON canonique. Il construit une chaîne UTF-8 sans séparateur ni préfixe de longueur, dans cet ordre exact :

```text
v
alg.kem
alg.kdf
alg.aead
alg.sig
groupId
convId
messageId
sentAt
sender.userId
sender.deviceId
sender.eph_pub
sender.key_version
pour chaque recipient, dans l'ordre de la liste :
  recipient.userId
  recipient.deviceId
  recipient.key_version
  recipient.wrap
  recipient.nonce
iv
hex_lowercase(SHA-256(UTF8(payload.ciphertext)))
```

Toutes ces valeurs sont concaténées directement. Pour compatibilité, les
enveloppes V2 historiques sans `recipient.key_version` conservent exactement
l'ancienne concaténation et sélectionnent implicitement la version `1`. Le champ
`salt` est absent des octets signés.

La signature est :

```text
sig = Ed25519.sign(senderPrivateKey, UTF8(concatenation ci-dessus))
```

Limites importantes :

- l'absence de longueurs et de séparateurs rend la représentation ambiguë en principe ;
- l'ordre des destinataires devient une partie implicite du protocole ;
- le sel HKDF n'est pas authentifié par la signature ;
- cette construction n'est pas la canonicalisation sûre exigée pour la cible V3.

Elle doit être remplacée par une structure canonique, versionnée et testée avec des vecteurs dans `TC-302` et `TC-305`, sans changement silencieux du format V2 historique.

## Déchiffrement authentifié depuis TC-114

Pour l'appareil local :

1. valider version, algorithmes, types, tailles Base64 et unicité des destinataires ;
2. imposer l'égalité entre cercle/conversation attendus et enveloppe ;
3. imposer exactement une entrée pour l'utilisateur et l'appareil locaux ;
4. récupérer dans l'annuaire la version exacte de la clé expéditeur ; son état
   peut être `active`, `superseded` ou `revoked` pour vérifier un message déjà
   stocké, tandis que le backend interdit ces deux derniers états à l'envoi ;
5. vérifier Ed25519 dans l'isolate cryptographique ;
6. seulement après ce succès, consulter un éventuel cache de `MK` ;
7. à défaut, charger la version privée X25519 indiquée dans le wrap, calculer
   X25519/HKDF puis ouvrir `wrap` et le contenu dans l'isolate ;
8. mettre `MK` en cache uniquement après ouverture réussie du tag du contenu ;
9. remettre atomiquement le texte avec `signatureValid: true`.

Une signature absente, fausse ou invérifiable, un contexte inattendu, un appareil inactif, un wrap, nonce, sel ou tag altéré provoque un rejet sans texte, cache ou notification.

`decryptVerified` est désormais le chemin unique. Les méthodes historiques `decrypt` et `decryptFast` ne sont que des alias vers cette méthode ; malgré son ancien nom, `decryptFast` ne saute plus la signature. Les anciens services génériques capables de déchiffrer sans preuve d'enveloppe ont été retirés.

La réactivité est préservée par l'annuaire et les clés de message en cache après validation, ainsi que par une file d'isolate priorisant les messages visibles. Aucun aller-retour réseau supplémentaire n'est ajouté lorsque l'annuaire est disponible localement. Les mesures `message_signature_verify`, `message_decrypt_verified_cached`, `message_decrypt_verified_pipeline` et `message_receive_verified_total` exposent médiane/p95 sans journaliser le contenu.

## Stockage local et durée de vie

| Élément | Emplacement | Durée observée | État de sécurité |
|---|---|---:|---|
| graine d'identité Ed25519 compte/appareil | `flutter_secure_storage` | enrôlement du compte sur l'installation | création explicite, chargement fail-closed ; registre, preuve et approbation présents |
| graines privées E2EE Ed25519/X25519 | `flutter_secure_storage` | installation | stockage OS, sélection par compte/cercle/appareil/version ; anciennes versions conservées fail-closed |
| jetons d'accès/refresh | `flutter_secure_storage` | session/30 jours | biométrie autour du refresh à valider par plateforme |
| clé de message en mémoire | RAM | TTL 24 h, max. 1 000 | index utilisateur/appareil/message ; clés accessibles au processus |
| clé de message persistante | SQLite, chiffrée AES-GCM | TTL 7 jours | index utilisateur/appareil/message ; clé maître CSPRNG propre au compte |
| enveloppes de messages | `messages_encrypted.db` SQLite | non bornée clairement | fichier SQLite non chiffré, contenu E2EE conservé |
| texte déchiffré | objets/cache en RAM | session/cache | ne doit jamais être écrit ou journalisé |
| clé publique de groupe | cache local | TTL 30 jours | mécanisme historique, rôle V2 limité |

`LocalMessageStorage` génère une valeur appelée clé de base de données, mais `sqflite` n'utilise pas cette clé : le fichier n'est pas chiffré au repos.

Depuis le lot A de `TC-106`, `PersistentMessageKeyCache` crée une clé maître aléatoire de 32 octets par compte sous `message_key_master:v2:account:<userId>`. Les anciennes clés maîtres globales prévisibles ne sont plus sélectionnées. La pseudo-clé de base locale reste construite depuis l'horloge et, surtout, `sqflite` ne l'utilise pas : le chiffrement réel de SQLite et la migration/suppression maîtrisée des anciens caches restent dans `TC-306`.

## Métadonnées visibles du serveur

Le E2EE ne masque pas :

- les identifiants du cercle, de la conversation et du message ;
- l'identité utilisateur et appareil de l'expéditeur ;
- la liste des utilisateurs et appareils destinataires ;
- les versions de clés et la clé éphémère publique ;
- les heures, volumes, fréquence et taille des messages ;
- les nonces, le sel, les encapsulations, le chiffré et la signature ;
- la présence, la frappe et les accusés de lecture lorsqu'ils sont utilisés.

Le backend applique l'identité JWT à l'expéditeur depuis `TC-103`, mais il ne vérifie pas la signature Ed25519 du message : il agit comme relais et stockage d'une enveloppe opaque.

## Garanties et non-garanties actuelles

### Garanties raisonnablement visées par le code

- confidentialité du texte vis-à-vis d'un backend honnête ne possédant aucune clé privée de destinataire ;
- intégrité du contenu par le tag AES-GCM une fois la bonne `MK` obtenue ;
- possibilité d'authentifier l'enveloppe avec la clé Ed25519 attendue, si l'annuaire n'a pas été substitué et si le résultat est effectivement imposé avant usage ;
- séparation des enveloppes par appareil destinataire.

### Non-garanties

- aucune confidentialité des métadonnées listées ci-dessus ;
- aucune transparence ou preuve d'identité de l'annuaire de clés ;
- pas de forward secrecy face à la compromission ultérieure de la clé X25519 statique d'un destinataire et à l'enregistrement des enveloppes ;
- pas de post-compromise security ;
- pas de déniabilité ou d'anonymat ;
- pas de restauration automatique sûre de l'historique sur un nouvel appareil ;
- la rotation V2 n'apporte ni forward secrecy ni effacement cryptographique des anciennes versions ;
- pas de chiffrement complet de la base SQLite contenant les enveloppes et métadonnées ;
- pas de protocole complet anti-rejeu et de synchronisation par curseur.

## Cycle d'un nouvel appareil

Comportement actuellement implémenté dans le parcours nominal :

1. lors d'un enrôlement explicite, l'appareil crée son UUID et son identité Ed25519 de confiance propres au compte ;
2. il prouve la possession de cette clé sur la transcription serveur de 163 octets ; le premier appareil réautorisé par mot de passe devient `active`, les suivants restent `pending` ;
3. un appareil actif approuve ou refuse la cible en signant la transcription distincte de 216 octets ;
4. tant que la cible n'est pas `active`, le client bloque l'accueil, le WebSocket, les conversations et la publication des clés de cercle ;
5. après activation, le client crée et publie en arrière-plan une paire E2EE distincte pour chaque cercle ;
6. les futurs messages incluent une encapsulation pour ce nouvel appareil, tandis que les anciens messages sans encapsulation restent indéchiffrables.

Cette barrière est imposée côté client et côté serveur. Un client modifié doit
encore produire la preuve Ed25519 liée au token, être `active`, signer la liaison
de sa clé de cercle et respecter la version monotone. Une révocation signée
désactive toutes ses clés courantes en une transaction. Voir aussi `TC-303` et
`TC-304` pour le remplacement V3 et ses garanties plus fortes.

## Cas particulier de la création d'un cercle

L'interface génère d'abord des clés avec le **nom** du cercle avant l'appel de création, puis le client génère une autre paire sous l'UUID retourné et la publie comme clé d'appareil. Le backend ne conserve dans `group_keys` que la clé publique Ed25519 historique et ignore la clé KEM transmise lors de la création.

Les messages V2 utilisent les entrées par appareil de `group_device_keys`, pas cette clé publique de groupe. Ce double mécanisme doit être supprimé ou migré explicitement ; aucune clé privée ne doit être perdue silencieusement.

## Relation avec les jetons d'authentification

Le chiffrement E2EE et les JWT sont deux systèmes distincts :

- accès : JWT Ed25519, durée 15 minutes, signé seulement par Auth et vérifié par Auth/Messaging ;
- refresh : JWT HS256, durée 30 jours, émis et vérifié seulement par Auth, avec empreinte SHA-256 persistée ;
- E2EE : Ed25519/X25519/AES-GCM dans le client par appareil et par cercle.

Le JWT autorise une requête ; il ne prouve pas à lui seul l'authenticité cryptographique du contenu d'un message.

## Cible V3 et règles d'évolution

L'ADR [`ADR-0003-protocole-crypto-v3.md`](../adr/ADR-0003-protocole-crypto-v3.md) définit la direction : protocole formalisé, octets signés canoniques, preuve d'appareil, rotation, révocation, vecteurs interopérables et migration explicite.

Toute modification doit :

1. conserver un champ de version non ambigu ;
2. définir chaque octet signé et authentifié ;
3. lier cryptographiquement contexte, destinataires, sel, nonces et contenu ;
4. rejeter avant tout usage si signature, tag, version ou identité échoue ;
5. ne jamais régénérer silencieusement une identité ;
6. fournir des vecteurs positifs et négatifs indépendants de Flutter ;
7. définir la coexistence et la migration V2/V3 avant déploiement.

## Tests minimaux attendus

- vecteur déterministe de construction et de vérification d'enveloppe ;
- altération de chaque champ signé/authentifié entraînant un rejet ;
- permutation, ajout ou suppression d'un destinataire entraînant un rejet ;
- substitution de clé d'expéditeur détectée ;
- appareil révoqué exclu des nouveaux messages ;
- appareil nouvellement ajouté incapable de lire un ancien message sans partage explicite ;
- aucune remise de texte clair quand la signature est absente, invalide ou invérifiable ;
- aucune notification ou persistance de texte avant authentification ;
- migration V2/V3 et comportement sur clé locale corrompue testés.

## Références

- [`FUNCTIONAL_REFERENCE.md`](../architecture/FUNCTIONAL_REFERENCE.md)
- [`TRACEABILITY.md`](../architecture/TRACEABILITY.md)
- [`SECURITY_INVARIANTS.md`](SECURITY_INVARIANTS.md)
- [`THREAT_MODEL.md`](THREAT_MODEL.md)
- [`DATA_MAP.md`](../compliance/DATA_MAP.md)
- [`ADR-0003-protocole-crypto-v3.md`](../adr/ADR-0003-protocole-crypto-v3.md)
