# Modèle de données

Statut : photographie V2 et contraintes cibles
Dernière mise à jour : 2026-08-25

## Modèle observé

Le script `infrastructure/postgres/init.sql` définit :

- `users` : compte, e-mail, hash de mot de passe, nom ;
- `groups`, `user_groups` : cercle, appartenance et rôle `admin|member` ; l'unique propriétaire reste `groups.creator_id` ;
- `join_requests`, `join_request_votes` : demandes et votes d'entrée ;
- `group_keys`, `group_device_keys` : clés publiques par cercle/utilisateur/appareil ;
- `conversations`, `conversation_users` : conversation et participants ;
- `messages` : enveloppe E2EE V2 et clés de message enveloppées ;
- `refresh_tokens` : sessions renouvelables ;
- `notifications` : événements applicatifs utilisateur.

Le staging neuf a été recréé à partir du script courant et validé par `TC-004`. `TC-104` ajoute le premier couple SQL montant/descendant pour le rôle, à reprendre dans l'outil et la baseline qui seront choisis par `TC-201`.

La circulation de ces données par parcours est décrite dans [`FUNCTIONAL_REFERENCE.md`](FUNCTIONAL_REFERENCE.md), et les fichiers responsables dans [`TRACEABILITY.md`](TRACEABILITY.md).

## Problèmes structurels à résoudre

- Pas encore d'outil, de registre appliqué ni de baseline globale de migrations ; seul le changement TC-104 possède des scripts SQL versionnés.
- Le stockage des rôles est explicite, mais le transfert de propriété et l'interface complète de gestion restent à concevoir.
- Cycle de vie des appareils incomplet : preuve d'approbation, révocation, rotation et rattachement au compte.
- Horodatages mêlant `timestamp` et `timestamptz`.
- Énumérations métier parfois représentées par texte libre.
- Messages sans séquence serveur/cursor robuste pour la synchronisation.
- Notifications JSON génériques sans classification de sensibilité/version.
- Absence de tables explicites pour vérification e-mail, récupération, suppression, signalement/blocage et journal de sécurité minimal.

## Contraintes cibles

- Toute ligne métier sensible porte un identifiant stable, des horodatages UTC et, si nécessaire, une version optimiste.
- L'identité de l'auteur est écrite depuis le principal authentifié côté serveur.
- Appartenance et écriture associée sont vérifiées dans la même transaction ou protégées par une contrainte équivalente.
- Les identifiants de message fournis par le client sont uniques par domaine défini et rendent l'envoi idempotent.
- Une séquence serveur monotone par conversation ou un curseur opaque stable permet la reprise.
- Une clé révoquée ne peut plus être sélectionnée comme destinataire de nouveaux messages.
- Les refresh tokens sont hachés, rotatifs, liés à une session/appareil et révoquables ; leur type diffère cryptographiquement/logiquement des access tokens.
- Les suppressions et rétentions sont documentées dans `docs/compliance/DATA_MAP.md`.

## Règles de migration

1. Une migration est immuable après déploiement.
2. Chaque évolution fournit une stratégie `expand/migrate/contract` si deux versions applicatives peuvent coexister.
3. Les migrations destructrices exigent sauvegarde, test de restauration et approbation humaine.
4. La compatibilité avec les enveloppes cryptographiques historiques est explicitement testée.
5. Une migration ne journalise aucune donnée de message, clé ou jeton.

Le choix de l'outil de migration sera pris dans la phase `TC-201`; ce document ne l'impose pas encore.
