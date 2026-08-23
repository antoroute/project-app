# TC-705 — Notifications et distribution Windows

Statut : À faire
Priorité : P0 Windows
Décision : propriétaire du produit
Dépendances : TC-509, TC-703, TC-704

## Objectif

Livrer un MSIX x64 installable depuis le Microsoft Store, avec notifications génériques, mises à jour et désinstallation propres sur Windows 11 25H2+.

## Travail

- Ajouter initialisation et comportement Windows des notifications.
- Créer identité MSIX, assets, protocole d'URI et association de liens.
- Définir `MinVersion` cohérent avec Windows 11 25H2 et produire symboles publics.
- Tester installation, update, rollback applicatif possible et suppression des données locales selon le choix utilisateur.
- Exécuter Windows App Certification Kit et préparer les déclarations Store.

## Critères d'acceptation

- [ ] MSIX x64 construit en CI et accepté par le Certification Kit.
- [ ] Toast sans contenu, activation et permissions/notifications désactivées sont testés.
- [ ] Mise à jour conserve les données chiffrées ; retrait de compte les efface.
- [ ] Le Store fournit signature et distribution ; aucun EXE/MSI non signé n'est publié.

## Preuves

Hash MSIX, logs CI/WACK assainis, version Windows et résultats installation/mise à jour/désinstallation.
