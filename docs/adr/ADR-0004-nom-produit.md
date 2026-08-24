# ADR-0004 — Nom public du produit

Statut : Acceptée
Date : 2026-08-24
Tâche : `TC-001`

## Contexte

Le nom de travail « Trust Circle » entre en collision exacte avec plusieurs applications Android et iOS, dont une messagerie privée organisée autour de cercles de confiance. Le produit a besoin d'une identité distincte avant la réservation des domaines, bundle IDs, comptes stores et visuels.

Le propriétaire souhaite conserver « Trust Circle » dans le titre parce que cette expression représente bien la promesse du produit, tout en ajoutant une marque suffisamment reconnaissable.

## Décision

- Le nom public est **CircleHaven — Trust Circle**.
- La marque et le nom court sont **CircleHaven**, sans espace et avec deux majuscules.
- La forme ASCII est `CircleHaven - Trust Circle` lorsque le tiret cadratin n'est pas pris en charge.
- « Trust Circle » peut rester une signature de produit et désigner les cercles de confiance dans l'interface ; ce n'est plus la marque autonome.
- Les domaines prioritaires proposés sont `circlehaven.app` et `circlehaven.fr`.
- La racine proposée pour les identifiants techniques est `app.circlehaven`, uniquement après réservation effective de `circlehaven.app`.
- Le dépôt et le code historiques ne sont pas renommés dans cette ADR. Le renommage sera réalisé avec une migration dédiée après les vérifications et réservations.

## Options considérées

- **Trust Circle** seul : rejeté pour collisions exactes dans le même secteur.
- **Cercelya** : distinctif et domaines apparemment disponibles, mais ne conservait pas le nom apprécié par le propriétaire.
- **Trust Circle Haven** : conservait le nom en tête, mais rendait la nouvelle partie moins dominante.
- **CircleHaven — Trust Circle** : retenu comme compromis entre continuité, sens et distinction visible dans les stores.

## Conséquences

- Le titre tient dans la limite actuelle de 30 caractères des stores Apple et Google Play.
- `circlehaven.com` est déjà enregistré ; la stratégie Web ne doit pas en dépendre.
- `circlehaven.app` et `circlehaven.fr` paraissaient non enregistrés au contrôle du 2026-08-24, sans garantie tant qu'ils ne sont pas réservés.
- Une association américaine utilise « Circle Haven » et un ancien projet de bande dessinée a utilisé « CircleHaven ». Ces usages sont éloignés de la messagerie, mais doivent être inclus dans la recherche juridique.
- Le nom ne doit pas être présenté comme juridiquement disponible tant que les recherches INPI, EUIPO et WIPO ne sont pas finalisées.

## Sécurité et migration

Le changement de nom n'altère ni le protocole cryptographique ni les invariants de sécurité. La future migration devra cependant éviter de casser les URLs d'API, deep links, associations de liens, stockage sécurisé, signatures, bundle IDs et mises à jour des installations existantes.

Aucun domaine ou identifiant technique n'est réservé par cette décision seule. Une dépense, la création d'un compte externe ou la publication de coordonnées exigent l'autorisation explicite du propriétaire.

## Réexamen

Réexaminer cette ADR si la recherche de marque révèle un conflit pertinent dans les classes 9, 38, 42 ou 45, si les domaines prioritaires deviennent indisponibles, ou si un store refuse le titre.
