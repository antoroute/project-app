# Sauvegarde et restauration

Statut : politique cible, preuve requise par `TC-003`
Dernière mise à jour : 2026-08-23

## Objectifs provisoires

Les valeurs RPO/RTO doivent être décidées après mesure de la charge et des attentes de bêta. Jusqu'alors, aucune affirmation de reprise garantie ne doit être publiée.

## Contenu

- PostgreSQL : schéma, données et métadonnées nécessaires à une restauration cohérente.
- Configuration déclarative : Compose, proxy, migrations et versions d'images sont versionnés séparément.
- Secrets : sauvegardés par un mécanisme dédié chiffré, jamais dans le dump ou le dépôt.
- Clés privées E2EE clientes : ne sont pas sauvegardées par le serveur sauf future conception explicitement approuvée et chiffrée côté client.

## Exigences

- Format de sauvegarde PostgreSQL permettant validation et restauration sélective.
- Chiffrement avant sortie de la zone de confiance, contrôle d'accès et rétention définie.
- Copie hors de la VM afin qu'une perte de disque ou compromission ne détruise pas toutes les sauvegardes.
- Somme de contrôle, journal de succès/échec sans données sensibles et alerte en cas d'échec.
- Test de restauration périodique sur une base isolée, jamais par-dessus production.

## Preuve de restauration

1. Sélectionner une sauvegarde par identifiant/date.
2. Créer une base isolée avec des secrets propres au test.
3. Restaurer avec la version PostgreSQL compatible.
4. Vérifier migrations, contraintes, volumes de lignes et intégrité référentielle.
5. Lancer les smoke tests applicatifs sans notifier de vrais utilisateurs.
6. Mesurer durée et écart au point de restauration.
7. Détruire l'environnement de test selon une procédure approuvée et conserver uniquement le rapport assaini.

## Critère de réussite TC-003

Une sauvegarde de production chiffrée existe hors VM et une restauration isolée a été réalisée avec un rapport daté, sans secret ni donnée personnelle exposée. Le runbook exact, la rétention et les responsables sont alors ajoutés à ce document.
