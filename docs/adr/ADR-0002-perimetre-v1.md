# ADR-0002 — Périmètre fonctionnel V1

Statut : Proposée
Date : 2026-08-23
Décision attendue : `TC-005`

## Contexte

Le dépôt et ses README évoquent messagerie, documents, calendrier et localisation. L'état de sécurité et de qualité impose de réduire la surface avant publication.

## Décision proposée

La V1 se limite aux comptes, cercles privés, appareils, messages texte E2EE fiables, notifications génériques, blocage/signalement, paramètres de confidentialité, support et suppression de compte. Les fonctionnalités listées comme exclues dans `docs/product/V1_SCOPE.md` sont reportées.

## Options considérées

- Périmètre large dès V1 : valeur démonstrative plus visible mais surface cryptographique, modération et compatibilité beaucoup trop grande.
- Messagerie texte fiable d'abord : moins spectaculaire, mais vérifiable et publiable.
- Client mobile uniquement : délai plus court, mais contredit l'exigence Windows explicite.

## Conséquences

- Le backlog de sécurité/fiabilité passe avant toute nouvelle fonction de contenu.
- Les dépendances de scanner peuvent être supprimées si les invitations n'exigent pas le QR en V1 desktop, ou abstraites avec un parcours de lien/code.
- L'architecture doit rester extensible sans prétendre implémenter les fonctions reportées.

## Critère d'acceptation

Le propriétaire tranche les questions ouvertes de `V1_SCOPE.md`; le document passe à `Accepté` et les tâches hors périmètre sont explicitement déplacées après lancement.
