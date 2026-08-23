# Invariants de sécurité

Statut : obligatoire pour toute modification
Dernière mise à jour : 2026-08-23

Ces règles décrivent ce qui doit rester vrai indépendamment de l'interface ou de l'implémentation. Une tâche qui semble exiger leur violation doit s'arrêter et ouvrir une décision d'architecture.

## Identité et sessions

1. Le serveur dérive toujours l'utilisateur depuis un access token vérifié ; un `userId` client n'est jamais une preuve d'identité.
2. Access token et refresh token ont des types, audiences/usages et cycles de vie distincts. Un refresh token ne donne accès à aucune autre route que son échange/sa révocation.
3. La validation impose algorithme, signature, `typ`, `iss`, `aud`, `exp` et, lorsque défini, `nbf`/version de session.
4. L'absence d'un secret ou paramètre cryptographique serveur critique fait échouer le démarrage. Aucun fallback de développement n'existe dans un artefact de production.
5. Les mots de passe, jetons et codes de récupération ne sont jamais journalisés et sont stockés sous forme adaptée à leur fonction.

## Autorisation

6. Toute lecture ou écriture de cercle, conversation, message, membre ou clé vérifie l'appartenance et le rôle côté serveur.
7. La vérification d'autorisation et l'écriture dépendante sont atomiques ou protégées contre le changement concurrent.
8. Le principe du moindre privilège s'applique aux rôles applicatifs, comptes PostgreSQL, conteneurs, réseaux et opérations humaines.
9. Un objet inaccessible renvoie une erreur qui ne révèle pas inutilement son existence.

## Appareils et clés

10. Une clé publique d'appareil n'est active qu'après une preuve de contrôle et un processus d'approbation défini.
11. Les appareils et clés sont rattachés à l'identité du compte ; aucun cache global ne peut survivre silencieusement à un changement de compte.
12. Une révocation empêche immédiatement l'utilisation de la clé pour les nouveaux messages et se propage de manière déterministe.
13. Les clés privées ne quittent pas l'appareil en clair. Leur stockage utilise les mécanismes sécurisés de l'OS et une stratégie explicite de sauvegarde/récupération.
14. Toute génération de clé, nonce, sel ou jeton utilise un CSPRNG. L'heure, un compteur ou `Random()` non sécurisé sont interdits.

## Messages E2EE

15. Une enveloppe est versionnée, sérialisée canoniquement et liée à son domaine : version, algorithmes, cercle, conversation, message, expéditeur, appareil, destinataires et horodatage utiles sont authentifiés.
16. La signature, le contexte, la clé et l'autorisation sont validés avant déchiffrement exploitable, affichage, indexation ou notification locale.
17. Une erreur de signature/déchiffrement est visible comme état de sécurité, sans afficher le contenu non vérifié.
18. Aucun contenu en clair, clé, secret, enveloppe déchiffrée ou donnée sensible n'est placé dans les logs, analytics, rapports de crash ou push.
19. Le serveur ne possède pas les clés nécessaires pour lire le contenu E2EE. Les métadonnées qu'il conserve sont décrites honnêtement.
20. Les propriétés « forward secrecy » et « post-compromise security » ne sont revendiquées que si le protocole retenu les fournit et que les tests/audits les démontrent.

## Fiabilité et données

21. Un envoi possède un identifiant idempotent, une outbox durable et une machine d'état ; une coupure ne crée ni perte silencieuse ni duplication visible.
22. La synchronisation utilise un curseur déterministe et reprend après reconnexion/redémarrage.
23. Les données locales sensibles sont réellement chiffrées au repos et la clé de base n'est pas stockée avec la base.
24. Toute modification de schéma passe par une migration versionnée testée en montée, compatibilité et restauration.
25. La suppression et la rétention respectent le contrat produit, y compris les limites inhérentes aux copies E2EE déjà reçues par d'autres appareils.

## Livraison et exploitation

26. Aucun secret serveur ou `APP_SECRET` partagé n'est embarqué dans une application distribuée.
27. Les builds release utilisent des identifiants, signatures et configurations propres à chaque environnement.
28. Une action de production exige cible confirmée, accès minimal, sauvegarde restaurable, observabilité, rollback et approbation humaine explicite.
29. Les sauvegardes sont chiffrées, leur accès est audité et leur restauration est testée périodiquement.
30. Les documents stores et confidentialité décrivent le comportement réel de la version soumise.

## Validation

Chaque invariant affecté doit être relié à au moins un test automatisé ou à une procédure de preuve explicite. Les revues de sécurité utilisent les numéros ci-dessus pour rendre leur couverture traçable.
