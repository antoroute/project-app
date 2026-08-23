# Checklist de release

Statut : modèle V1
Dernière mise à jour : 2026-08-23

## Produit

- [ ] Périmètre et notes de version gelés.
- [ ] Parcours essentiels validés en français et anglais.
- [ ] Support, blocage/signalement et suppression de compte opérationnels.
- [ ] Aucune fonction non terminée visible ou annoncée.

## Sécurité et confidentialité

- [ ] Invariants de sécurité couverts et revue des changements réalisée.
- [ ] Audit de dépendances, secrets et images sans critique/haute exploitable ouverte.
- [ ] Tests négatifs JWT/ACL/crypto/multi-compte réussis.
- [ ] Journaux, push, analytics et crash reports inspectés pour absence de contenu/secrets.
- [ ] Modèle de menace et carte des données à jour.
- [ ] Audit cryptographique/pentest requis clôturé ou risque explicitement accepté avant bêta publique.

## Données et opérations

- [ ] Migrations testées depuis la version effectivement en production.
- [ ] Rollback compatible démontré.
- [ ] Sauvegarde récente hors VM et restauration de preuve réussie.
- [ ] Healthchecks, alertes, espace disque et certificats vérifiés.
- [ ] Incident contacts/runbooks accessibles hors dépôt.

## Qualité par plateforme

- [ ] Android release signé, bundle ID définitif, AAB installé depuis la piste de test.
- [ ] iOS archive signée, entitlements/push/deep links et TestFlight validés.
- [ ] Windows package signé, installation/mise à jour/désinstallation validées sur versions cibles.
- [ ] macOS signé/notarisé et sandbox/entitlements validés si inclus.
- [ ] Accessibilité, permissions, mode sombre, réseau faible, redémarrage et mise à jour testés.
- [ ] Crash-free et seuils de fiabilité bêta atteints selon la décision produit.

## Stores et légal

- [ ] Nom, identité éditeur, domaines, visuels et coordonnées support définitifs.
- [ ] Politique de confidentialité, conditions et URL de suppression publiées.
- [ ] Formulaires de données/confidentialité cohérents avec la version.
- [ ] Modération UGC, blocage, signalement et contact vérifiés.
- [ ] Exigences cryptographiques/export applicables validées.
- [ ] SDK/OS/format de soumission revérifiés sur les sources officielles le jour de la release.

## Go/No-Go

La décision enregistre version, commit, digests, responsables, preuves, risques acceptés et plan de rollback. Une case critique non cochée implique No-Go.
