# Contrats API

L'inventaire des routes et événements **observés dans le code** se trouve dans [`FUNCTIONAL_REFERENCE.md`](../architecture/FUNCTIONAL_REFERENCE.md). Il fait foi pour comprendre le prototype tant que l'OpenAPI ci-dessous n'a pas été réconcilié et rendu contractuel.

Statut : contrat existant à réconcilier
Dernière mise à jour : 2026-08-23

Le dépôt contient actuellement `docs/openapi/openapi-v2.yaml`. Il décrit une partie des routes et le format cryptographique V2, mais l'audit n'a pas établi une correspondance complète avec le comportement du code. Il ne doit donc pas encore être utilisé comme preuve de sécurité ni comme unique source de génération client.

## Règles cibles

- Chaque route indique l'authentification, les autorisations, les limites, l'idempotence et les codes d'erreur.
- Aucun schéma d'écriture n'accepte un `userId` comme identité faisant autorité.
- Les formats binaires précisent l'encodage, la longueur et la version.
- Toute erreur externe est stable et ne divulgue ni secret ni détail interne.
- Toute rupture de contrat passe par une nouvelle version ou une période de compatibilité documentée.
- Le contrat est validé en CI et testé contre l'implémentation.

La remise à niveau du contrat fait partie des tâches backend et crypto ultérieures. Ne pas créer un second fichier OpenAPI concurrent avant d'avoir choisi la source canonique.
