# Contrat des jetons d'authentification

Statut : contrat initial appliqué par `TC-102`
Dernière mise à jour : 2026-08-24

## Séparation des usages

| Propriété | Access token | Refresh token |
|---|---|---|
| Usage | routes REST protégées et Socket.IO | `/auth/refresh` et `/auth/logout` uniquement |
| Clé | `JWT_ACCESS_SECRET` | `JWT_REFRESH_SECRET` |
| Issuer | `trust-circle-auth` | `trust-circle-auth` |
| Audience | `trust-circle-api` | `trust-circle-auth` |
| Claim `typ` | `access` | `refresh` |
| Durée | 15 minutes | 30 jours |
| Stockage serveur | aucun | empreinte SHA-256 dans `refresh_tokens.token_hash` |

Les clés sont obligatoires, distinctes et générées par CSPRNG. Messaging reçoit uniquement la clé access. `APP_SECRET` est indépendant et temporaire jusqu'à `TC-109`.

## Header et claims obligatoires

- Header : `alg=HS256` et `typ=JWT`.
- Claims : `sub`, `iss`, `aud`, `iat`, `exp`, `jti`, `typ`, `ver`.
- `sub` : UUID du compte.
- `jti` : UUID aléatoire unique généré pour chaque jeton.
- `ver` : entier `1` pour ce contrat.
- `iat` et `exp` : entiers et `exp > iat`.
- `nbf` : facultatif ; lorsqu'il existe, il doit être entier et le token est refusé avant cette date sans tolérance configurée.

La validation cryptographique impose l'algorithme, la clé, l'issuer, l'audience, l'expiration, l'âge maximal et le header `typ`. Une seconde validation impose la forme du sujet, du `jti`, du type d'usage et de la version.

## Émission et stockage

Auth est le seul service qui émet les deux types de jetons. Le JWT complet n'est jamais journalisé ni stocké côté serveur. Pour un refresh token, PostgreSQL conserve :

```sql
encode(digest(token, 'sha256'), 'hex')
```

Cette empreinte couvre le JWT complet et remplace bcrypt, dont la limite de 72 octets rendait son usage impropre pour ces chaînes longues. La signature du JWT apporte une entropie suffisante pour rendre une recherche hors ligne irréaliste ; la clé de signature n'est pas stockée en base.

## Erreurs et confidentialité

- Token absent : HTTP 401 sur une route qui l'exige.
- Token invalide, expiré, trop ancien, pas encore actif ou destiné à un autre usage : HTTP 401 générique.
- Refresh révoqué/inconnu : HTTP 401.
- `/auth/logout` sans token reste idempotent et retourne succès ; un token fourni mais non conforme est refusé.
- Socket.IO retourne une erreur générique `invalid token`, sans claim ni valeur du token.

## Migration et évolution

Le passage à ce contrat invalide tous les anciens refresh tokens et les anciens access tokens dépourvus des claims requises. Une reconnexion est obligatoire. Une future rotation à usage unique, les familles de sessions et la révocation par appareil relèvent de `TC-403`.

HS256 implique que les services possédant la clé access peuvent techniquement émettre un access token. Un passage à une signature asymétrique pourra réduire ce périmètre de confiance ; il exigera une ADR, une rotation versionnée et une distribution sûre des clés publiques.
