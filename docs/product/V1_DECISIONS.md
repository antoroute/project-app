# Décisions produit V1

Statut : accepté comme baseline V1
Date : 2026-08-23
Tâche : `TC-005`

Ces décisions transforment le périmètre V1 en comportement testable. Une modification exige une décision explicite de changement de scope et une mise à jour de l'ADR-0002.

## 1. Conversations et cercles

Toutes les conversations V1 appartiennent à un cercle.

- Un cercle possède une conversation principale.
- Une conversation privée peut réunir un sous-ensemble des membres du même cercle.
- Aucun message individuel global n'existe entre deux comptes sans cercle commun.
- Une conversation ne peut jamais contenir un utilisateur extérieur à son cercle.

Cette contrainte réduit les erreurs d'autorisation et rend l'origine de la confiance visible dans l'interface.

## 2. Rôles

La V1 utilise trois rôles :

| Rôle | Capacités principales |
|---|---|
| Propriétaire | toutes les capacités, transfert de propriété, suppression du cercle |
| Administrateur | approuver/refuser membres, retirer membre, modérer et gérer les conversations |
| Membre | lire/écrire selon la conversation, créer une invitation soumise à approbation, quitter le cercle |

Chaque cercle possède exactement un propriétaire. Le dernier propriétaire ne peut pas quitter ou supprimer son compte sans transférer la propriété ou supprimer le cercle.

## 3. Approbations

- Nouveau membre : approbation par le propriétaire ou un administrateur.
- Nouvel appareil : approbation depuis un appareil déjà autorisé du même compte, avec preuve de possession de la nouvelle clé.
- Aucun quorum ou vote collectif en V1.
- Si aucun appareil autorisé ne subsiste, le parcours de récupération crée une nouvelle identité cryptographique ; il ne contourne pas l'approbation de clé.

Les membres du cercle voient les changements sensibles de membres et d'identités d'appareil.

## 4. Historique d'un nouvel appareil

Un appareil nouvellement approuvé reçoit uniquement les messages envoyés après son approbation.

- Aucun ancien secret de message n'est automatiquement transféré par le serveur.
- L'historique reste disponible sur les appareils qui le possèdent déjà.
- Un transfert chiffré d'historique entre appareils est reporté après la V1 et exigera une ADR dédiée.
- L'interface explique cette limite avant la confirmation du nouvel appareil.

Ce choix réduit fortement la complexité cryptographique et le risque qu'un nouvel appareil compromis révèle tout l'historique.

## 5. Perte totale et récupération

Si tous les appareils autorisés et leurs clés sont perdus :

1. le compte peut être récupéré après vérification renforcée du contrôle de l'adresse e-mail ;
2. toutes les anciennes sessions et clés d'appareil sont révoquées ;
3. une nouvelle identité cryptographique est créée ;
4. les cercles affichent un changement d'identité à leurs membres ;
5. l'ancien historique E2EE reste inaccessible sur le nouvel appareil ;
6. les nouveaux messages reprennent après validation des nouvelles clés.

La récupération d'un compte ne promet jamais de récupérer un contenu dont les clés ont été perdues.

## 6. Plateformes de lancement

- Obligatoires : Android, iOS et Windows.
- macOS : objectif post-V1 ou simultané seulement si la matrice qualité est prête ; son absence ne bloque pas la V1 obligatoire.
- Web : site public statique seulement.

Cette décision est cohérente avec ADR-0001 et sera détaillée techniquement dans `TC-006`.

## 7. Rétention

### Serveur

- Enveloppes de messages chiffrées : 90 jours après réception serveur, ou suppression du cercle/compte si elle intervient avant.
- Au-delà, le serveur ne garantit plus la resynchronisation du message.
- Les métadonnées de sécurité, comptes, appartenances et obligations de suppression ont leurs propres durées à définir dans la cartographie de données.
- Les sauvegardes futures devront purger les données expirées selon leur cycle documenté.

### Appareil

- Les messages vérifiés restent localement tant que le compte demeure présent sur l'appareil et que l'utilisateur ne les supprime pas.
- « Retirer ce compte de cet appareil » efface la base locale, les jetons et les clés du compte.
- La suppression côté serveur ne peut pas effacer une copie déjà reçue par un autre membre ; cette limite est expliquée dans le produit et la politique de confidentialité.

La durée de 90 jours est une baseline de bêta. Son changement nécessite une décision produit, une analyse de coût/confidentialité et une mise à jour des déclarations stores.

## 8. Personas initiaux

### Camille — organisatrice familiale

Crée un cercle familial, invite des proches, veut comprendre qui peut entrer et souhaite que les messages arrivent même après une coupure réseau.

### Alex — proche peu technique

Reçoit une invitation, attend un onboarding court, des erreurs compréhensibles et aucun vocabulaire cryptographique nécessaire pour converser.

### Sam — utilisateur multi-appareil

Utilise un téléphone et Windows, veut approuver clairement son ordinateur, voir ses appareils actifs et révoquer immédiatement un appareil perdu.

## 9. Parcours acceptés

| Parcours | Résultat attendu | Échec acceptable et visible |
|---|---|---|
| Compte | e-mail vérifié, session créée, appareils visibles | délai/erreur avec retry ; aucune session partielle |
| Récupération | nouvel accès et nouvelle identité sûre | ancien historique annoncé inaccessible |
| Cercle | création/invitation/approbation avec rôle clair | invitation expirée/refusée sans appartenance partielle |
| Appareil | preuve, approbation, notification puis nouveaux messages | appareil refusé reste sans clé ni contenu |
| Message | outbox, envoi idempotent, vérification avant affichage | état échoué/retry ; jamais de perte silencieuse |
| Hors ligne | lecture locale et reprise déterministe | délai visible, pas de doublon |
| Blocage/signalement | action accessible et accusé de réception | indisponibilité support visible avec nouvelle tentative |
| Suppression | compte retiré, sessions révoquées, rétention expliquée | délai de traitement annoncé, jamais de fausse confirmation |

## 10. Seuils de bêta fermée

Population minimale : 30 participants activés, au moins 5 cercles réels de test, pendant 4 semaines.

| Indicateur | Seuil Go |
|---|---|
| Activation en 24 h | au moins 70 % des invités terminent compte + cercle + premier message |
| Livraison en ligne | au moins 99,5 % des messages confirmés en moins de 60 secondes |
| Perte/duplication silencieuse | zéro dans les scénarios automatisés et incidents bêta confirmés |
| Reprise après reconnexion | p95 inférieur à 5 secondes pour 100 messages en attente dans le test de référence |
| Crash-free sessions | au moins 99,5 % sur chaque plateforme annoncée |
| Erreur crypto inexpliquée | zéro |
| Incident d'accès croisé/ACL | zéro |
| Rétention D7 activés | au moins 40 %, indicateur produit et non gate de sécurité |
| Parcours essentiels sans aide | au moins 80 % des participants du test d'utilisabilité |

Ces métriques ne collectent aucun contenu, clé ou détail de conversation. Leur instrumentation exacte exige une ADR analytics avant intégration. Les gates de sécurité restent bloquants même si les objectifs d'usage sont atteints.

## 11. Règle de changement de scope

Calendrier, fichiers, localisation, appels, client Web, messages hors cercle et monétisation restent post-V1. Une demande pour les réintroduire doit préciser valeur, menace, données, plateformes, modération, tests, coût et tâche déplacée hors du chemin critique avant acceptation.
