# TC-003 — Sauvegarde chiffrée et restauration prouvée

Statut : Terminée par abandon explicite des données historiques
Priorité : P0
Autorisation : propriétaire de la production
Dépendances : TC-002

## État de départ observé le 2026-08-23

- PostgreSQL est arrêté depuis le 18 décembre 2025 et son volume local fait environ 46 Mio.
- La filiation du volume doit être clarifiée : son étiquette Docker est plus récente que ses fichiers internes.
- Une archive complète de LXC106 du 9 août 2026 existe sur le stockage de transit Proxmox et sa somme a été déclarée vérifiée.
- Aucune copie hors hôte récente, sauvegarde PostgreSQL dédiée ou restauration Trust Circle n'est démontrée.
- Ne pas démarrer la stack historique avant d'avoir préservé le volume et défini la cible de restauration isolée.

## Objectif

Créer une sauvegarde cohérente de PostgreSQL, chiffrée et copiée hors de la VM, puis démontrer qu'elle restaure une application exploitable dans un environnement isolé.

## Décision de clôture du 2026-08-23

Le propriétaire a confirmé que les données historiques n'avaient aucune valeur à conserver et a autorisé leur suppression. Les anciennes stacks `app`/`infra`, leurs conteneurs, volumes PostgreSQL/Redis, réseaux, images personnalisées et copies de sources Portainer ont été supprimés.

L'objectif initial de sauvegarde/restauration n'a donc pas été exécuté et ne doit pas être présenté comme une preuve de restauration. La porte vers TC-004 est levée parce qu'aucune donnée historique n'est reprise. Une archive complète du LXC datée du 9 août peut encore contenir l'ancien volume jusqu'à sa rotation, mais elle n'est pas la base du nouveau staging.

La nouvelle base de staging repart vide. La sauvegarde/restauration devra être implémentée et testée pour la future production dans `TC-208`, avant toute bêta contenant des données à conserver.

## Préconditions

- Version PostgreSQL, taille, volumes, mécanisme actuel et espace libre connus.
- Destination hors VM et mécanisme de chiffrement choisis.
- Identifiants de sauvegarde à privilèges minimaux disponibles hors prompt/Git.
- Fenêtre et impact du dump évalués.
- Base de restauration isolée, sans connexion aux vrais utilisateurs, e-mails ou push.

## Travail

1. Définir RPO/RTO provisoires, format, fréquence, rétention et responsable.
2. Produire un dump cohérent avec la version réelle, sans secret dans le nom ou les logs.
3. Chiffrer, calculer une somme de contrôle et transférer hors VM.
4. Vérifier que l'accès au backup est limité et révocable.
5. Restaurer dans une base isolée vide avec secrets propres.
6. Vérifier schéma, contraintes, comptages agrégés et démarrage des services de test.
7. Exécuter des smoke tests avec comptes synthétiques ou procédure ne divulguant aucune donnée réelle.
8. Mesurer durée, noter les avertissements et corriger le runbook.
9. Automatiser et alerter sur l'échec après réussite manuelle comprise.

## Risques

- Charge ou verrouillage de production pendant le dump.
- Fichier temporaire en clair laissé sur la VM.
- Restauration accidentelle vers production.
- E-mails/push envoyés depuis la restauration.
- Version PostgreSQL/outils incompatible ou extensions manquantes.

Chaque risque doit recevoir un contrôle explicite dans le runbook avant exécution.

## Critères d'acceptation

- [ ] Backup daté, chiffré, vérifié et stocké hors VM.
- [ ] Aucun secret n'apparaît dans Git, terminal partagé ou rapport.
- [ ] Restauration terminée dans une cible isolée explicitement vérifiée.
- [ ] Intégrité référentielle et smoke tests réussissent.
- [ ] Durée de sauvegarde/restauration et point de données sont connus.
- [ ] Rétention, rotation, alerte et responsable sont définis.
- [ ] `BACKUP_RESTORE.md` contient le runbook assaini et la date de dernière preuve.

Ces critères restent la définition d'une vraie capacité de reprise. Ils sont non applicables à l'instance historique abandonnée et ne sont pas cochés artificiellement.

## Preuve de purge

- [x] Décision explicite du propriétaire reçue.
- [x] Cibles résolues par labels Compose avant suppression.
- [x] Six anciens conteneurs supprimés.
- [x] Volumes `infra_pgdata` et `infra_redisdata` supprimés.
- [x] Réseaux `app_backend_net` et `db_net` supprimés.
- [x] Images personnalisées `app-*` et `infra-postgres` supprimées.
- [x] Copies Portainer 143/149, dont l'ancien `stack.env`, supprimées.
- [x] Absence finale des ressources vérifiée.

## Rollback

La création d'un backup ne change pas les données. Si elle dégrade la production, interrompre proprement le processus selon l'outil retenu et vérifier santé/espace disque. La restauration ne doit jamais cibler production dans cette tâche.
