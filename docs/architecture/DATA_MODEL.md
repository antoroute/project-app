# Modèle de données

Statut : photographie V2 et contraintes cibles
Dernière mise à jour : 2026-08-23

## Modèle observé

Le script `infrastructure/postgres/init.sql` définit :

- `users` : compte, e-mail, hash de mot de passe, nom ;
- `groups`, `user_groups` : cercle et appartenance ;
- `join_requests`, `join_request_votes` : demandes et votes d'entrée ;
- `group_keys`, `group_device_keys` : clés publiques par cercle/utilisateur/appareil ;
- `conversations`, `conversation_users` : conversation et participants ;
- `messages` : enveloppe E2EE V2 et clés de message enveloppées ;
- `refresh_tokens` : sessions renouvelables ;
- `notifications` : événements applicatifs utilisateur.

Le schéma réellement déployé peut différer. Seul l'inventaire `TC-002`, puis une migration de référence, permettront de le confirmer.

## Problèmes structurels à résoudre

- Pas d'historique de migrations ni de table de version de schéma.
- Rôles de cercle insuffisamment explicites ; certaines décisions semblent dépendre du créateur ou d'un vote implicite.
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
