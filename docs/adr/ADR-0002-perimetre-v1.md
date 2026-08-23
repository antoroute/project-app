# ADR-0002 — Périmètre fonctionnel V1

Statut : Acceptée
Date : 2026-08-23
Décision : `TC-005`

## Contexte

Le dépôt et ses README évoquent messagerie, documents, calendrier et localisation. L'état de sécurité et de qualité impose de réduire la surface avant publication.

## Décision

La V1 se limite aux comptes, cercles privés, appareils, messages texte E2EE fiables, notifications génériques, blocage/signalement, paramètres de confidentialité, support et suppression de compte. Les fonctionnalités listées comme exclues dans `docs/product/V1_SCOPE.md` sont reportées.

Toutes les conversations appartiennent à un cercle. Les rôles sont propriétaire, administrateur et membre. Propriétaire ou administrateur approuve un membre ; un appareil existant approuve un nouvel appareil. Aucun quorum n'est utilisé. Un nouvel appareil ne reçoit que les messages futurs et une récupération totale crée une nouvelle identité sans ancien historique.

Android, iOS et Windows sont obligatoires. macOS ne bloque pas le lancement. Les enveloppes E2EE restent 90 jours sur le serveur par défaut ; la conservation locale dépend de l'appareil et de l'utilisateur.

## Options considérées

- Périmètre large dès V1 : valeur démonstrative plus visible mais surface cryptographique, modération et compatibilité beaucoup trop grande.
- Messagerie texte fiable d'abord : moins spectaculaire, mais vérifiable et publiable.
- Client mobile uniquement : délai plus court, mais contredit l'exigence Windows explicite.

## Conséquences

- Le backlog de sécurité/fiabilité passe avant toute nouvelle fonction de contenu.
- Les dépendances de scanner peuvent être supprimées si les invitations n'exigent pas le QR en V1 desktop, ou abstraites avec un parcours de lien/code.
- L'architecture doit rester extensible sans prétendre implémenter les fonctions reportées.

## Validation

Le propriétaire du produit a accepté le plan centré particuliers puis la clôture de cette étape. Les décisions détaillées, parcours et seuils sont enregistrés dans `docs/product/V1_DECISIONS.md`. Une modification future crée une nouvelle ADR ou remplace explicitement celle-ci.
