# Réponse aux incidents

Statut : baseline à opérationnaliser avant bêta externe
Dernière mise à jour : 2026-08-23

## Niveaux

- SEV-1 : compromission possible de clés/secrets, accès croisé aux cercles, corruption/perte majeure, service indisponible généralisé.
- SEV-2 : faille exploitable limitée, dégradation importante, notifications ou synchronisation largement défaillantes.
- SEV-3 : incident localisé sans exposition connue, contournement disponible.

## Réponse

1. Détecter et ouvrir une chronologie en UTC.
2. Préserver les preuves sans copier contenu E2EE, secrets ou données inutiles.
3. Contenir : révoquer accès/sessions ou isoler un composant selon le risque.
4. Évaluer portée, versions, utilisateurs et données concernées.
5. Corriger et valider en environnement isolé.
6. Restaurer progressivement avec surveillance renforcée.
7. Communiquer honnêtement et effectuer les notifications réglementaires applicables après conseil compétent.
8. Produire un post-mortem sans blâme, avec tâches datées et tests de non-régression.

## Scénarios nécessitant un runbook dédié

- Secret JWT ou base de données exposé.
- Appareil/clé ajouté sans autorisation ou clé privée client compromise.
- Accès à un cercle/conversation d'un autre utilisateur.
- Base supprimée/corrompue ou sauvegardes inutilisables.
- Image/dépendance compromise.
- Certificat expiré, DNS/proxy détourné ou push compromis.
- Publication store défectueuse nécessitant retrait/rollback.

## Contacts et outils

Les coordonnées personnelles, accès d'urgence, fournisseurs et emplacements de secrets ne doivent pas être versionnés dans ce dépôt public. Avant bêta, créer un registre privé avec responsable primaire, remplaçant, hébergeur, conseil juridique/notification et procédure de révocation.
