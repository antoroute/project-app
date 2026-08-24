# TC-102 — Séparer access/refresh JWT et valider toutes les claims

Statut : En cours
Priorité : P0 sécurité
Décision : mainteneur, avec revue sécurité
Dépendances : TC-101

## Objectif

Garantir qu'un refresh token ne puisse jamais authentifier une route REST ou Socket.IO et qu'un access token ne puisse jamais être échangé ou révoqué comme refresh token. Chaque vérification impose la clé, l'algorithme, l'issuer, l'audience, le type, la version et les bornes temporelles attendus.

## Constat initial

- Access et refresh tokens sont signés avec le même `JWT_SECRET`.
- Auth, Messaging et Socket.IO vérifient principalement la signature et l'expiration, sans contrat strict commun de claims.
- Le refresh porte `typ=refresh`, mais l'access token ne porte aucun type et les middlewares protégés n'interdisent pas le refresh.
- Les refresh tokens complets sont hachés avec bcrypt/PostgreSQL `crypt`, dont la limite d'entrée de 72 octets n'est pas adaptée à des JWT longs.

## Périmètre

- Émission et vérification JWT dans Auth.
- Vérification des access tokens dans Messaging REST et Socket.IO.
- Configuration Docker du staging et contrat OpenAPI.
- Empreinte des refresh tokens dans la table existante, sans changement de schéma.

## Hors périmètre

- Rotation à usage unique, famille de sessions et révocation par appareil (`TC-403`).
- Dérivation systématique de l'identité dans toutes les routes métier (`TC-103`).
- Suppression de `APP_SECRET` (`TC-109`).
- Modification de la production.

## Contrat cible

- Algorithme : `HS256`, explicitement imposé à la signature et à la vérification.
- Header : `typ=JWT`.
- Issuer : `trust-circle-auth`.
- Access : clé `JWT_ACCESS_SECRET`, audience `trust-circle-api`, claim `typ=access`, durée 15 minutes.
- Refresh : clé `JWT_REFRESH_SECRET`, audience `trust-circle-auth`, claim `typ=refresh`, durée 30 jours.
- Claims obligatoires : `sub`, `iss`, `aud`, `iat`, `exp`, `jti`, `typ` et `ver=1`.
- Toute claim `nbf` présente est vérifiée ; aucune tolérance ne permet un token pas encore actif.
- `sub` et `jti` sont des UUID générés ou validés ; aucune valeur de jeton n'est journalisée.

## Invariants affectés

- Invariant 1 : identité dérivée d'un access token vérifié.
- Invariant 2 : usages, audiences et cycles de vie distincts.
- Invariant 3 : algorithme, signature et claims strictement validés.
- Invariant 5 : aucun jeton dans les logs ; empreinte adaptée au stockage.

## Travail

1. Remplacer `JWT_SECRET` par deux clés obligatoires et distinctes côté Auth, et uniquement la clé access côté Messaging.
2. Centraliser constantes, émission et validation des claims dans chaque service.
3. Protéger `app.authenticate` et Socket.IO par le validateur access strict.
4. Vérifier le refresh avec sa clé et son audience sur `/auth/refresh` et `/auth/logout`.
5. Remplacer `crypt(..., gen_salt('bf'))` par une empreinte SHA-256 déterministe du token avant stockage/comparaison.
6. Ajouter les tests positifs et négatifs : type croisé, mauvaise clé/issuer/audience/algorithme, claims absentes, expiration et `nbf` futur.
7. Mettre à jour OpenAPI, configuration et smoke tests.
8. Redéployer uniquement `trust-circle-staging` avec une nouvelle clé refresh et accepter l'invalidation de ses sessions synthétiques.

## Critères d'acceptation

- [ ] Clés access/refresh distinctes, obligatoires et jamais affichées.
- [ ] REST Auth, REST Messaging et Socket.IO refusent tout refresh token.
- [ ] `/auth/refresh` et `/auth/logout` n'acceptent qu'un refresh token valide.
- [ ] Algorithme, header `typ`, issuer, audience, expiration, sujet, identifiant, type et version sont imposés.
- [ ] Un `nbf` futur est refusé.
- [ ] Les nouveaux refresh tokens sont stockés par empreinte SHA-256 complète, jamais en clair ni via bcrypt tronqué.
- [ ] Tests automatisés et builds passent dans les deux services.
- [ ] Le staging est sain et les smoke tests prouvent les usages croisés négatifs.
- [ ] Migration de session, contrat et rollback sont documentés.

## Migration et rollback

Le déploiement invalide volontairement tous les refresh tokens antérieurs, car la clé, l'audience et le format changent. Les utilisateurs devront se reconnecter ; le staging ne contient que des comptes synthétiques. Le rollback remet les images et métadonnées de release précédentes, mais ne doit pas réactiver une ancienne clé en production sans décision explicite. Aucun changement de production n'est autorisé dans cette tâche.
