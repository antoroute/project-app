# TC-704 — Fournir les invitations Windows sans scanner

Statut : À faire
Priorité : P0 Windows
Décision : produit
Dépendances : TC-607, TC-703

## Objectif

Permettre de rejoindre et d'approuver un cercle sur Windows sans charger `mobile_scanner`, qui ne supporte pas Windows.

## Travail

- Isoler le scanner derrière une capacité de plateforme.
- Implémenter lien HTTPS vérifié, protocole d'URI applicatif et code court saisissable/copiable.
- Expirer, borner et rendre à usage unique les invitations côté serveur.
- Afficher cercle, invitant et conséquence avant acceptation ; ne jamais placer de secret durable dans le lien.
- Tester activation depuis navigateur, application fermée/ouverte et code invalide/rejoué.

## Critères d'acceptation

- [ ] Le build Windows ne référence aucun plugin scanner non supporté.
- [ ] Invitation valide, expirée, forgée, déjà utilisée et destinée à un autre compte sont testées.
- [ ] Le même lien fonctionne sur Android/iOS et le QR n'est qu'un encodage du lien/code.
- [ ] Aucun compte n'est ajouté sans approbation conforme à ADR-0002.

## Preuves

Tests d'intégration backend, tests Flutter de routage et parcours manuel Windows enregistré sans donnée réelle.
