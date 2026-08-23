# TC-004 — Créer un staging isolé

Statut : Terminée — staging backend local ; exposition client différée
Priorité : P0
Autorisation : propriétaire de l'infrastructure
Dépendances : TC-002, TC-003

## Objectif

Disposer d'un environnement reproductible pour tester migrations, déploiements, protocoles, notifications et clients sans toucher à la production.

## Exigences

- Domaine(s), base, volumes, réseaux, secrets JWT/DB, comptes SMTP/push et certificats distincts.
- Données synthétiques par défaut ; aucune copie brute de production.
- E-mails et notifications restreints à une allowlist de test ou à des fournisseurs sandbox.
- Bannière/identité visuelle « STAGING » et protection d'accès adaptée.
- Images déployées par digest avec commit/version visibles.
- Healthchecks, logs redacted, métriques et alertes de base.
- Possibilité de recréer l'environnement depuis le dépôt et le mécanisme privé de secrets.

## Travail

1. Choisir l'hébergement et documenter les frontières réseau.
2. Créer secrets/identités séparés et comptes à privilèges minimaux.
3. Paramétrer proxy TLS, DNS et restriction d'accès.
4. Déployer PostgreSQL puis les services avec healthchecks.
5. Charger migrations/fixtures synthétiques.
6. Déployer une build cliente explicitement liée à l'URL staging.
7. Tester démarrage, auth, cercles, message, Socket.IO et redémarrage.
8. Tester une migration et un rollback simples, puis la procédure de restauration de TC-003.
9. Documenter coûts, responsables, mise en veille éventuelle et nettoyage sûr.

## Critères d'acceptation

- [x] Aucun endpoint, secret, volume ou fournisseur production n'est partagé.
- [x] L'environnement se déploie à partir d'un commit/digests enregistrés.
- [x] Fixtures reproductibles et comptes de test sont disponibles hors secrets versionnés.
- [x] E-mails/push ne peuvent atteindre un utilisateur réel.
- [x] Smoke tests et reprise après recréation des conteneurs réussissent.
- [x] `ENVIRONMENTS.md` et `DEPLOYMENT.md` contiennent le runbook assaini.

La restauration d'un backup n'est pas revendiquée : les données historiques ont été abandonnées et la sauvegarde de la future production est reportée à TC-208. Le staging a démontré la persistance du nouveau volume après `down/up`.

## Hors périmètre

- Haute disponibilité de production.
- Copie complète des données réelles.
- Déploiement automatique en production.

## Décisions d'implémentation du 2026-08-23

- Nom Compose unique : `trust-circle-staging`.
- PostgreSQL conservé comme base ; nouvelle base et nouveau volume vides.
- Redis retiré car aucun code backend ne l'utilise.
- Gateway initialement liée au loopback du LXC sur le port 18080.
- Aucun domaine historique ou secret n'est réutilisé.
- Images tierces par digest ; images backend avec commit/version OCI.
- Stack source : `deploy/staging/compose.yml`.

L'exposition TLS et la configuration Flutter staging seront réalisées après les smoke tests locaux et avant les tests sur appareils.

## Résultat du 2026-08-23

- [x] Stack `trust-circle-staging` déployée avec quatre services sains.
- [x] PostgreSQL 16 neuf, 12 tables initialisées, données synthétiques uniquement.
- [x] Redis supprimé de l'architecture déployée.
- [x] Secrets générés avec CSPRNG et fichier `0600` hors Git.
- [x] Auth/messaging/gateway non-root, read-only et limités en ressources.
- [x] Gateway accessible uniquement sur le loopback du LXC.
- [x] Tests health, auth, groupe, rejet secret et Socket.IO réussis.
- [x] Recréation complète des conteneurs/réseaux et persistance réussies.
- [x] Inventaire publié dans `docs/operations/STAGING_INVENTORY.md`.

Le domaine TLS et le client Flutter ne font pas partie de cette première exposition : ils sont différés jusqu'à la fermeture des vulnérabilités critiques afin de ne pas publier un prototype connu comme contournable.
