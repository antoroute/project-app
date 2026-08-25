# Contexte du projet

Statut : référence de travail
Dernière mise à jour : 2026-08-25
Instantané fonctionnel documenté : branche `main`, changement `TC-106` lot A

## Mission

**CircleHaven — Trust Circle** est une messagerie privée destinée d'abord aux familles et groupes d'amis. Sa promesse centrale est une conversation de cercle simple, fiable et chiffrée de bout en bout, sans lecture du contenu des messages par l'opérateur du service.

Le propriétaire a choisi **CircleHaven** comme marque et **CircleHaven — Trust Circle** comme nom public le 2026-08-24. « Trust Circle » seul reste uniquement le nom historique du dépôt. La décision et les collisions résiduelles sont documentées dans `product/NAME_DECISION.md` et `adr/ADR-0004-nom-produit.md`. La vérification formelle de la marque, les réservations et le renommage technique restent requis. Dans l'intervalle, le domaine réseau provisoire est précisément `trust-circle.kavalek.fr`, sans wildcard ; il reste remplaçable et sans incidence sur le nom public.

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
- Cryptographie actuelle : X25519, HKDF-SHA256, AES-256-GCM et Ed25519 côté Flutter, protocole maison V2 décrit dans `docs/security/CRYPTOGRAPHY_V2.md` et à remplacer ou formaliser avant publication.

## Niveau de préparation

Le projet est un prototype fonctionnel, pas une version publiable. Les builds TypeScript et les suites locales Auth/Messaging réussissent. Un SDK Flutter 3.47.1 temporaire a permis de faire passer 24 tests ciblés de sécurité/cryptographie et de confirmer l'absence d'erreur ou avertissement bloquant dans l'analyse statique ; les builds release et tests sur appareils restent à réaliser. La couverture automatisée demeure partielle et aucune CI n'est encore en place.

Les principaux bloqueurs restants sont : cycle de vie multi-appareil incomplet côté serveur, stockage SQLite insuffisamment protégé, protocole cryptographique non audité, fiabilité hors ligne fragile, compatibilité desktop incomplète, configuration de release non préparée et absence d'un véritable outil de migrations. La confusion entre access et refresh tokens a été fermée par `TC-102`, l'identité d'envoi est dérivée du JWT par `TC-103`, les autorisations cercle/conversation/rôle sont centralisées par `TC-104`, et `TC-105` rend atomiques les contrôles et écritures Messaging critiques avec événements post-commit. Le lot A de `TC-106` isole les identités et caches locaux par compte et interdit la régénération silencieuse des clés ; l'ADR-0005 doit encore fixer l'ancrage serveur. `TC-114` impose désormais l'authentification du message avant tout usage du texte — sous réserve des mesures finales Android/Windows. L'inventaire Docker détaillé est dans `docs/operations/PRODUCTION_INVENTORY.md`.

## Ordre de travail

1. Stabiliser le cadre : nom, inventaire de production, sauvegarde, staging, périmètre V1 et plateformes (`TC-001` à `TC-008`).
2. Fermer les vulnérabilités backend et supprimer les secrets publics partagés.
3. Introduire migrations, observabilité sûre, sauvegarde et déploiement reproductible.
4. Décider puis implémenter le protocole cryptographique V3 et le vrai multi-appareil.
5. Terminer le cycle de compte, la synchronisation fiable et la résilience hors ligne.
6. Reprendre l'UX, l'accessibilité, l'internationalisation et les adaptations de plateforme.
7. Automatiser tests/CI, réaliser les audits puis préparer les stores.

La roadmap détaillée se trouve dans `docs/roadmap/ROADMAP.md`.

Pour reprendre rapidement le projet, lire ensuite `docs/architecture/FUNCTIONAL_REFERENCE.md`, `docs/security/CRYPTOGRAPHY_V2.md` et `docs/architecture/TRACEABILITY.md`. Ces documents distinguent explicitement comportement observé, cible et écart.

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
