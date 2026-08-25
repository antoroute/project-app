# Modèle de menace

Statut : baseline V1, document vivant
Dernière mise à jour : 2026-08-25

## Périmètre et objectifs

Le modèle couvre le client Flutter, les services auth/messaging, PostgreSQL, le proxy, les notifications, la chaîne de livraison et les opérateurs. Il vise confidentialité et authenticité du contenu, contrôle des appartenances, disponibilité raisonnable et récupération explicable.

Il ne promet pas l'anonymat, la résistance à un appareil déjà compromis, la protection contre les captures d'écran ni la disparition d'un contenu déjà reçu par un autre membre.

## Actifs

- Clés privées d'identité/appareil, clés de message et matériaux de récupération.
- Mots de passe, refresh/access tokens et sessions.
- Contenu en clair sur les appareils et enveloppes chiffrées.
- Graphe social : comptes, cercles, membres, appareils, conversations et horaires.
- Disponibilité et ordre des messages.
- Intégrité des applications, images Docker, dépendances et mises à jour.
- Sauvegardes, journaux et accès d'administration.

## Adversaires considérés

- Client non authentifié ou membre malveillant d'un autre cercle.
- Membre légitime tentant de dépasser son rôle.
- Attaquant réseau malgré TLS, proxy compromis ou fournisseur push curieux.
- Opérateur serveur curieux ou base de données exfiltrée.
- Voleur d'un appareil verrouillé ou déverrouillé.
- Dépendance, image ou pipeline de build compromis.
- Administrateur ou assistant recevant accidentellement un secret.
- Spam, harcèlement, contenu abusif et automatisation d'inscription.

## Menaces prioritaires et contrôles attendus

| Menace | Exemple | Contrôles obligatoires |
|---|---|---|
| Usurpation | `sender.userId` forgé, token de mauvais type | Identité dérivée du JWT strict, sessions rotatives, tests négatifs |
| Élévation de privilège | ajout de membre/clé sans rôle | ACL centralisées, transactions, matrice de rôles, journal de sécurité |
| Substitution de clé | appareil hostile enregistré pour une victime | preuve de possession, approbation, transparence/changement visible, révocation |
| Altération/rejeu | enveloppe ou destinataire modifié | format canonique signé, contexte lié, identifiant unique, anti-rejeu |
| Divulgation locale | base SQLite ou clé récupérée | stockage OS, base réellement chiffrée, effacement à la déconnexion |
| Divulgation serveur | logs/push/sauvegarde lisibles | contenu E2EE, logs minimisés, push générique, sauvegardes chiffrées |
| Perte/duplication | réseau intermittent, retry | outbox durable, idempotence, ACK/cursor, tests de chaos réseau |
| Déni de service | spam, payload volumineux, sockets | quotas, limites de schéma/taille, rate limits, backpressure, alertes |
| Supply chain | paquet/image malveillant | versions verrouillées, scans, provenance, CI protégée, mises à jour testées |
| Erreur d'exploitation | mauvaise VM, migration destructive | environnements séparés, inventaire, sauvegarde/restauration, rollback approuvé |
| Abus utilisateur | harcèlement, invitations répétées | blocage, signalement, limites, support, politique et modération proportionnée |

## Scénarios à tester en priorité

1. Un utilisateur A envoie un message avec l'identifiant de B.
2. Un refresh token appelle une route messaging.
3. Un non-membre crée/lit une conversation ou publie une clé dans un cercle.
4. Deux requêtes concurrentes changent une appartenance pendant une écriture.
5. Une enveloppe modifie conversation, destinataires, clé/version ou horodatage après signature.
6. Un ancien appareil révoqué reçoit ou publie encore des clés/messages.
7. Déconnexion de A puis connexion de B sur le même appareil avec caches existants.
8. Envoi répété après timeout et redémarrage du client.
9. Exfiltration de PostgreSQL et des sauvegardes sans appareils clients.
10. Notification et rapport de crash inspectés pour vérifier l'absence de contenu.
11. Une session volée tente d'enrôler un appareil sans posséder la clé privée annoncée.
12. Deux appareils tentent simultanément le bootstrap initial ou rejouent le même challenge.

## Risques résiduels à communiquer

- Le serveur voit encore des métadonnées nécessaires au service.
- Un membre autorisé peut recopier ce qu'il voit.
- Un appareil compromis pendant son utilisation peut exposer contenu et clés.
- La disponibilité dépend de l'infrastructure auto-hébergée et de ses sauvegardes.
- Le protocole V2 actuel n'offre pas les garanties modernes attendues tant que l'ADR crypto V3 n'est pas clôturée et implémentée.

## Entretien

Mettre ce document à jour lors de tout nouveau type de contenu, fournisseur tiers, mécanisme de récupération, changement de protocole, plateforme, collecte analytics ou nouvelle frontière de déploiement.
