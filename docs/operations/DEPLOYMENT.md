# Déploiement

Statut : garde-fous définis, runbook VM à compléter après `TC-002`
Dernière mise à jour : 2026-08-23

## Préconditions

- Cible et environnement confirmés.
- Commit/tag et digests immuables identifiés.
- CI verte, revue terminée, contrat et migrations validés en staging.
- Sauvegarde récente et restauration testée selon la classe de changement.
- Plan de rollback écrit et fenêtre/observabilité disponibles.
- Autorisation humaine explicite pour la production.

## Séquence cible

1. Capturer l'état avant déploiement sans secret : versions, santé, schéma, espace disque et dernière sauvegarde vérifiée.
2. Appliquer les migrations compatibles vers l'avant.
3. Déployer les images par digest, avec healthchecks et limites de ressources.
4. Exécuter les smoke tests : authentification, renouvellement, liste de cercles, synchronisation et temps réel avec comptes de test dédiés.
5. Observer erreurs, latence, saturation et files pendant la fenêtre définie.
6. Enregistrer le résultat et clôturer ou déclencher le rollback.

## Rollback

Un rollback applicatif ne doit pas écrire sur un schéma devenu incompatible. Employer les migrations `expand/migrate/contract` pour permettre la coexistence. La restauration complète de base est un dernier recours avec perte potentielle depuis le point de sauvegarde ; son autorisation et son impact doivent être explicites.

## Interdictions

- Déployer `latest` sans digest vérifié.
- Modifier manuellement une table ou un secret pour contourner une migration.
- Reconstruire une image directement sur la VM.
- Publier des variables, logs bruts ou sorties contenant des secrets dans une conversation d'assistance.
- Déployer simultanément code, protocole crypto et migration destructive sans stratégie de compatibilité.

## À documenter par TC-002/TC-004

Noms réels des stacks et services, domaines assainis, réseau/proxy, registre d'images, emplacement des volumes, healthchecks, mécanisme de secrets, chemin de promotion et commandes exactes. Le document public ne contiendra aucune valeur sensible.
