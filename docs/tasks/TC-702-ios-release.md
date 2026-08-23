# TC-702 — Préparer iOS/iPadOS pour la publication

Statut : À faire
Priorité : P0 release
Décision : propriétaire du produit
Dépendances : TC-001, TC-006, TC-611

## Objectif

Produire une archive iOS/iPadOS arm64 pour iOS 15+, signable et distribuable par TestFlight/App Store, avec capacités minimales et comportement adaptatif.

## Travail

- Remplacer le bundle `com.example`, fixer deployment target 15 et versioning.
- Utiliser Xcode 26+ et le SDK iOS 26+ ; enregistrer l'environnement exact.
- Configurer Keychain, Associated Domains, APNs, caméra et biométrie avec descriptions localisées.
- Séparer configuration publique et secrets ; ne jamais versionner profils ou clés de signature.
- Tester iPhone et iPad, reprise arrière-plan, verrouillage, notifications et deep links.

## Critères d'acceptation

- [ ] Build et archive sans signature réussissent en CI ; archive signée réussit sur le compte Apple.
- [ ] Installation iOS 15 et version courante testées sur appareils réels.
- [ ] Refus de chaque permission conserve un parcours utilisable par lien/code.
- [ ] TestFlight passe les parcours compte, appareil, cercle et message sans blocage plateforme.
- [ ] Privacy manifest, entitlements et déclarations App Store correspondent au binaire.

## Preuves

Logs assainis, hash d'archive, rapport d'entitlements, appareils/OS et résultat TestFlight.
