# Contexte du projet

Statut : référence de travail
Dernière mise à jour : 2026-08-23
Instantané de code audité : branche `main`, commit `1988bf6`

## Mission

Trust Circle est une messagerie privée destinée d'abord aux familles et groupes d'amis. Sa promesse centrale est une conversation de cercle simple, fiable et chiffrée de bout en bout, sans lecture du contenu des messages par l'opérateur du service.

Le nom « Trust Circle » est provisoire jusqu'à la clôture de `TC-001` : une application très proche existe déjà sur Google Play et une vérification de marque reste à faire.

## Cible de publication

- Obligatoire pour la V1 : Android 9/API 28+, iOS/iPadOS 15+ et Windows 11 25H2+ x64.
- Souhaité si la compatibilité est démontrée : macOS 14+ sur Apple Silicon.
- Web V1 : site public statique avec présentation, téléchargements, support, confidentialité et suppression de compte. Aucun client de messagerie Web n'est prévu en V1.

## Architecture actuelle

- Client : Flutter/Dart dans `frontend-mobile/flutter_message_app`.
- Authentification : Fastify/TypeScript/PostgreSQL dans `backend/auth`.
- Messagerie : Fastify/TypeScript/Socket.IO/PostgreSQL dans `backend/messaging`.
- Données : PostgreSQL ; présence de Redis dans l'infrastructure, sans intégration applicative démontrée.
- Déploiement : Docker Compose et Nginx sur un LXC Docker partagé. Les stacks historiques ont été supprimées par décision du propriétaire. Un backend staging neuf, nommé `trust-circle-staging`, est opérationnel uniquement sur le loopback du LXC ; voir `docs/operations/STAGING_INVENTORY.md`.
- Contrat d'API existant : `docs/openapi/openapi-v2.yaml`, à réaligner avec le code avant de le considérer comme contractuel.
- Cryptographie actuelle : X25519, HKDF-SHA256, AES-256-GCM et Ed25519 côté Flutter, protocole maison V2 à remplacer ou formaliser avant publication.

## Niveau de préparation

Le projet est un prototype fonctionnel, pas une version publiable. Les builds TypeScript ont réussi lors de l'audit initial. Flutter/Dart n'étaient pas installés dans l'environnement d'audit ; aucun build client n'a donc été validé. Il n'existe ni suite de tests significative ni CI.

Les principaux bloqueurs sont : autorisations backend contournables, confusion entre jetons d'accès et de rafraîchissement, cycle de vie multi-appareil incomplet, stockage local insuffisamment protégé, protocole cryptographique non spécifié/audité, fiabilité hors ligne fragile, compatibilité desktop incomplète, configuration de release non préparée et absence de processus de migration/sauvegarde/restauration éprouvé. L'inventaire Docker détaillé est dans `docs/operations/PRODUCTION_INVENTORY.md`.

## Ordre de travail

1. Stabiliser le cadre : nom, inventaire de production, sauvegarde, staging, périmètre V1 et plateformes (`TC-001` à `TC-008`).
2. Fermer les vulnérabilités backend et supprimer les secrets publics partagés.
3. Introduire migrations, observabilité sûre, sauvegarde et déploiement reproductible.
4. Décider puis implémenter le protocole cryptographique V3 et le vrai multi-appareil.
5. Terminer le cycle de compte, la synchronisation fiable et la résilience hors ligne.
6. Reprendre l'UX, l'accessibilité, l'internationalisation et les adaptations de plateforme.
7. Automatiser tests/CI, réaliser les audits puis préparer les stores.

La roadmap détaillée se trouve dans `docs/roadmap/ROADMAP.md`.

## Décisions et limites actuelles

- Le cœur de sécurité ne sera jamais réservé à un abonnement payant.
- Le modèle économique n'est pas implémenté en V1 ; priorité à la validation d'usage auprès des particuliers.
- Calendrier, fichiers, localisation, appels, client Web complet et paiement sont hors V1 acceptée.
- Toutes les conversations V1 appartiennent à un cercle ; aucun message individuel hors cercle commun.
- Les rôles sont propriétaire, administrateur et membre, sans quorum d'approbation en V1.
- Un nouvel appareil ne reçoit que les nouveaux messages ; une récupération totale ne restaure pas l'ancien historique E2EE.
- Les enveloppes chiffrées sont conservées 90 jours sur le serveur par défaut.
- Ne pas affirmer « confidentialité parfaite », « forward secrecy », « post-compromise security » ou « équivalent Signal » tant que ces propriétés n'ont pas été conçues, testées et auditées.
- L'E2EE protège le contenu, pas automatiquement les métadonnées telles que comptes, appartenances, appareils, horodatages, adresses réseau et journaux techniques.

## Conventions pour le travail assisté

Une intervention doit partir d'une fiche `TC-xxx`, conserver un périmètre testable et produire des preuves de validation. Utiliser les prompts de `docs/prompts/` et respecter `AGENTS.md`. Les secrets et données réelles de production ne doivent jamais entrer dans le contexte d'un assistant.

## Points à ne pas déduire du dépôt

- La version effectivement déployée sur la VM.
- Les valeurs de configuration et l'état des certificats.
- Le schéma réel de production, les volumes, sauvegardes et règles réseau.
- L'éligibilité juridique du nom ou les déclarations cryptographiques nécessaires.

Ces éléments doivent être établis par inventaire ou validation explicite, puis documentés sans secret. L'état au 2026-08-23 est désormais inventorié, mais tout état futur doit être revérifié avant intervention.
