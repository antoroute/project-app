# TC-002 — Inventorier la VM de production en lecture seule

Statut : Terminée — écarts transmis aux tâches suivantes
Priorité : P0
Décision/autorisation : propriétaire de la VM
Dépendances : accès lecture seule ou exécution accompagnée

## Objectif

Établir ce qui est réellement déployé sans modifier le service et sans exposer de secret ou de donnée personnelle.

## Garde-fous

- Confirmer l'hôte et l'environnement avant toute commande.
- N'exécuter que des lectures. Pas de `pull`, `restart`, `up`, `down`, `prune`, `exec` applicatif mutatif, édition ou changement de permissions.
- Ne jamais afficher `docker inspect` brut, `env`, fichiers `.env`, secrets Docker, chaînes de connexion, certificats privés ou contenu de base.
- Pour les variables, collecter uniquement leurs noms et indiquer « présent/absent ».
- Assainir utilisateurs, IP publiques, domaines privés et chemins personnels si le document doit être versionné.

## Inventaire à relever

### Hôte

- Distribution/version, architecture, noyau, fuseau, stockage libre et mémoire globale.
- Versions Docker/Compose et mode de gestion (Compose/Portainer/autre).
- Synchronisation temporelle et politique de mises à jour, sans la modifier.

### Conteneurs et images

- Noms de stacks/services, statut, santé, durée de fonctionnement.
- Images exactes, tags, digests, labels de commit/version lorsqu'ils existent.
- Ports publiés et réseaux, sans dumping complet de configuration.
- Healthchecks, politiques de redémarrage et limites CPU/mémoire.

### Données

- Noms logiques des volumes, service consommateur, taille approximative et existence d'une copie hors VM.
- Version PostgreSQL, nom de la base assaini, version de schéma/migrations disponible.
- Liste des tables/colonnes uniquement si autorisée ; aucun échantillon de ligne.
- Présence/rôle de Redis et exposition réseau.

### Entrée réseau

- Chaîne DNS → proxy TLS → services, ports publics et certificats (émetteur/expiration seulement).
- Règles pare-feu pertinentes et origine des connexions PostgreSQL/Redis.
- Configuration CORS et proxy de confiance observée, sans secret.

### Sauvegardes et opérations

- Jobs, fréquence, dernière réussite, destination logique, chiffrement, rétention et dernière restauration testée.
- Emplacement des manifests versionnés et méthode de déploiement actuelle.
- Journaux, métriques, alertes et contacts d'incident disponibles.

## Livrable

Créer `docs/operations/PRODUCTION_INVENTORY.md` avec : date UTC, périmètre, état assaini, écarts par rapport au dépôt, risques, éléments inconnus et preuves non sensibles. Conserver les détails sensibles dans un emplacement privé indiqué seulement par son propriétaire.

## Critères d'acceptation

- [ ] Aucun changement d'état de la VM n'a été effectué.
- [ ] Commit/digests déployés et versions des composants sont connus.
- [ ] Routage TLS, ports, réseaux et volumes sont cartographiés.
- [ ] Schéma/mécanisme de migration et état de sauvegarde sont connus.
- [ ] Les noms des configurations critiques ont un statut présent/absent sans valeur divulguée.
- [ ] Les écarts dépôt/production et risques P0 sont listés.
- [ ] Le document versionné ne contient aucun secret ni donnée personnelle réelle.

## Validation

Le propriétaire relit le rapport assaini avant son ajout à Git. Tout doute sur une sortie sensible impose de ne pas la copier et de résumer manuellement le constat.

## Résultat du 2026-08-23

Le rapport est disponible dans `docs/operations/PRODUCTION_INVENTORY.md`.

- [x] La cible LXC106 et les sources Portainer réelles ont été identifiées.
- [x] Aucun conteneur, volume, réseau, service ou règle n'a changé d'état.
- [x] Les images, IDs, dates, ports, réseaux, volumes et noms de variables ont été relevés sans valeur sensible.
- [x] Les hashes des sources Portainer correspondent au dépôt local.
- [x] L'absence de provenance exacte des images est documentée comme écart.
- [x] L'état arrêté du backend, de PostgreSQL et de Redis est établi.
- [x] TLS, exposition, absence de listener et timeouts publics sont établis.
- [x] La sauvegarde LXC existante et l'absence de sauvegarde/restauration PostgreSQL dédiée sont établies.
- [x] Le schéma réel, inaccessible sans démarrage, est explicitement conservé comme inconnue pour TC-003.
- [x] Le rapport versionné ne contient aucune valeur de secret ni donnée applicative.

Une analyse Compose a créé deux fichiers temporaires filtrés sous `/tmp`; ils ont été supprimés immédiatement et leur absence a été vérifiée. Aucune donnée ni état de service n'a été modifié.
