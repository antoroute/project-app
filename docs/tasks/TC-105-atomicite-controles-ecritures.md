# TC-105 — Rendre atomiques les contrôles et écritures critiques

Statut : Terminée
Priorité : P0 sécurité et intégrité
Décision : mainteneur, avec preuve PostgreSQL
Dépendances : TC-104

## Contexte et problème

`TC-104` centralise les décisions d'accès, mais plusieurs routes vérifient encore une autorisation sur une connexion PostgreSQL puis écrivent avec une autre. Une révocation, une rétrogradation ou un traitement concurrent peut donc intervenir entre le contrôle et l'écriture. Certaines opérations composées peuvent aussi laisser un cercle, une conversation ou une adhésion partiellement créé si une requête intermédiaire échoue.

Les événements Socket.IO sont actuellement proches des écritures mais ne sont pas tous explicitement séparés de la frontière de commit. Ils ne doivent jamais annoncer une opération ensuite annulée.

## Objectif mesurable

- Fournir une primitive de transaction PostgreSQL commune, typée, testable et à rollback garanti.
- Exécuter contrôle ACL verrouillé et écriture dépendante sur la même connexion pour chaque mutation critique Messaging.
- Verrouiller uniquement les lignes nécessaires, avec un ordre stable, afin de limiter blocages et deadlocks.
- Émettre les événements Socket.IO uniquement après un commit réussi.
- Remplacer le contrôle N+1 des destinataires de message par une validation groupée, afin que la sécurité n'allonge pas le temps de chargement ou d'envoi proportionnellement au nombre d'appareils.

## Périmètre

- Plugin PostgreSQL de Messaging et interface d'exécution transactionnelle.
- Création d'un cercle et de sa première appartenance/clé publique.
- Création et traitement des demandes d'adhésion, routes courante et legacy.
- Création d'une conversation et de tous ses participants.
- Publication/révocation de clé d'appareil sans possibilité de réactivation concurrente d'une clé révoquée.
- Envoi de message avec appartenance et clés actives verrouillées jusqu'à l'insertion.
- Accusé de lecture et changement de rôle.
- Contrainte versionnée empêchant plusieurs demandes `pending` pour un même utilisateur et cercle.

## Hors périmètre

- Preuve de possession, approbation et protocole complet de rotation/révocation des appareils (`TC-106`).
- Validation exhaustive des tailles et encodages (`TC-107`).
- Idempotence complète, outbox durable et curseur serveur (`TC-501` à `TC-503`).
- Choix définitif de l'outil et baseline de migrations (`TC-201`).
- Mutations Auth qui ne dépendent pas d'une autorisation métier concurrente.

## Invariants affectés

- Invariant 6 : toute écriture conserve le contrôle d'appartenance et de rôle serveur.
- Invariant 7 : contrôle et écriture dépendante partagent transaction et verrous.
- Invariant 9 : les conflits concurrents conservent des erreurs génériques.
- Invariant 12 : une révocation acquise ne peut être annulée par une publication concurrente.
- Invariant 24 : la nouvelle contrainte est migrée et son rollback est exercé.

## Stratégie retenue

1. La primitive `transaction` réserve un client du pool, exécute `BEGIN`, le callback exclusivement PostgreSQL, puis `COMMIT` ou `ROLLBACK` et libère toujours le client.
2. Les erreurs PostgreSQL transitoires `40001` et `40P01` peuvent être rejouées un nombre borné de fois. Aucun événement, log métier irréversible ou appel externe n'est placé dans le callback.
3. Les décisions ACL transactionnelles utilisent le même exécuteur et `FOR SHARE` sur les appartenances, rôles, conversations et clés dont dépend l'écriture. Les opérations d'adhésion se sérialisent par verrou du cercle car elles doivent protéger l'absence d'une appartenance.
4. Les événements temps réel et changements de room sont déclenchés seulement après résolution réussie de `transaction`.
5. La publication de clé utilise un upsert conditionnel qui ne met jamais à jour une ligne déjà `revoked`, même en concurrence.
6. Un index unique partiel protège en dernier ressort l'unicité de `(group_id, user_id)` lorsque `status = 'pending'`.

## Critères d'acceptation

- [x] La primitive transactionnelle commit, rollback, libère le client et rejoue seulement les erreurs transitoires prévues.
- [x] Aucun cercle ou conversation partiel ne subsiste après l'échec d'une écriture intermédiaire.
- [x] Une demande ne peut être acceptée/rejetée qu'une fois ; appartenance, clé et statut sont atomiques.
- [x] Deux créations concurrentes ne produisent pas plusieurs demandes `pending` pour le même cercle/utilisateur.
- [x] Une clé révoquée ne peut pas redevenir active par course entre publication et révocation.
- [x] L'envoi verrouille l'appartenance et les clés actives jusqu'à l'insertion et valide les destinataires en une requête groupée.
- [x] Accusé de lecture et changement de rôle ne présentent plus de fenêtre contrôle/écriture.
- [x] Aucun événement Socket.IO ni changement de room n'a lieu avant le commit ou après rollback.
- [x] Les refus et conflits ne révèlent pas davantage l'existence d'un objet inaccessible.
- [x] Migration montante/descendante, tests locaux, concurrence et smoke tests réussissent sur `trust-circle-staging` uniquement.

## Tests et preuves attendues

- Tests unitaires de la primitive transactionnelle : commit, rollback, libération et retry borné.
- Tests de routes avec transaction simulée et panne injectée, vérifiant zéro émission avant commit/rollback.
- Tests ACL vérifiant l'utilisation de l'exécuteur transactionnel et une seule requête destinataires.
- Test PostgreSQL réel de la migration et de l'index partiel.
- Scénarios concurrents staging : double demande, double décision et publication/révocation.
- `npm test`, `npm run build`, validation documentaire, shell et `git diff --check`.

## Migration et rollback

La migration ajoute uniquement un index unique partiel sur les demandes en attente. Avant application, elle échoue explicitement si des doublons existent ; aucune donnée n'est supprimée automatiquement. La descente retire uniquement cet index.

Le code précédent reste compatible avec l'index. En rollback applicatif, repointer d'abord vers la release `TC-104`, puis retirer l'index seulement si nécessaire. Une sauvegarde du staging est créée et vérifiée avant application réelle.

## Risques résiduels acceptés dans cette tâche

- L'absence de retrait de membre dans la V1 actuelle limite les courses observables, mais les verrous sont posés dès maintenant pour que cette future mutation ne contourne pas l'invariant 7.
- PostgreSQL reste une dépendance unique ; l'atomicité ne remplace ni outbox ni idempotence de livraison temps réel.
- Un événement peut ne pas être envoyé après un commit si le processus tombe exactement entre les deux ; ce problème relève de l'outbox (`TC-502`), pas d'une émission avant commit.

## Décisions humaines nécessaires

Aucune. La stratégie ne change ni parcours utilisateur ni modèle de rôle. Les attentes concurrentes concernent des opérations rares d'administration ; le chemin d'envoi est au contraire réduit d'un contrôle par destinataire à une requête groupée.

## Résultat et preuves

Implémentation applicative : commit `abf6b51abf2967b7ddd0d43020690b0fc4872e8c`.

- Auth : 17 tests réussis.
- Messaging : 41 tests réussis et build TypeScript réussi.
- Tests dédiés : commit/rollback/libération/retry borné, pannes injectées sans événement, ACL transactionnelle, requête groupée des destinataires et ordre commit puis émission.
- Migration `20260825_002_unique_pending_join_request` montée puis descendue dans un schéma PostgreSQL isolé ; unicité prouvée dans le sens montant et suppression effective dans le sens descendant.
- Sauvegarde staging vérifiée avant migration : `pre-tc105-20260825T123518Z.dump`, mode `0600`.
- Release staging : même commit, quatre services sains, zéro redémarrage et zéro log d'erreur observé après déploiement.
- Smoke test réel réussi en 2 secondes : conversation, lecture et message, double demande concurrente `201/409`, double décision `200/403`, publication/révocation concurrente avec état final `revoked`.
- Vérification SQL finale : aucun doublon `pending`, index partiel présent, aucun cercle sans appartenance créateur, aucune conversation sans participant créateur et aucune demande acceptée sans appartenance ou clé d'appareil.

Le staging uniquement a été modifié. La production n'a pas été touchée. Le rollback applicatif reste la release `f0e1baa7db2cd9c0e0cfd1104f477af25eec5b9f` ; le script descendant de la migration a été exercé isolément.
