# TC-001 — Valider le nom et l'identité du produit

Statut : En cours — nouveau nom à choisir par le propriétaire
Priorité : P0
Décision : propriétaire du produit, avec conseil juridique si nécessaire
Dépendances : aucune

## Contexte

Le nom de travail est « Trust Circle ». Les recherches du 2026-08-24 ont confirmé plusieurs applications homonymes, dont une messagerie privée au positionnement très proche sur Google Play et une application de sécurité familiale sur Android et iOS. La synthèse et la shortlist sont dans `docs/product/NAME_DECISION.md`.

## Objectif

Choisir un nom publiable et réserver une identité cohérente avant de figer les package IDs, domaines, comptes stores et visuels.

## Travail

1. Définir les pays de lancement et les classes de produits/services à couvrir.
2. Rechercher les noms identiques et proches sur Google Play, App Store, Microsoft Store et moteurs usuels.
3. Rechercher les marques pertinentes dans les bases INPI, EUIPO et, si besoin, WIPO.
4. Vérifier domaines principaux, réseaux sociaux et dépôts de code pertinents.
5. Évaluer prononciation, orthographe, traduction FR/EN et risque de confusion.
6. Produire une shortlist de trois noms avec preuves datées et une recommandation.
7. Faire valider juridiquement si l'exposition le justifie, puis choisir.
8. Seulement après décision, réserver domaines et identifiants techniques définitifs sans publier de coordonnées privées.

## Hors périmètre

- Créer le logo ou la campagne marketing complète.
- Renommer immédiatement tout le code avant décision.
- Considérer une recherche automatisée comme un avis juridique.

## Livrables

- `docs/product/NAME_DECISION.md` avec recherches, date, pays, risques et décision.
- Nom public, nom court, orthographe et capitalisation.
- Racines proposées pour bundle/package IDs et domaines.
- Liste privée séparée des réservations/comptes, sans secret dans Git.

## Critères d'acceptation

- [ ] Stores et bases de marques des marchés visés ont été vérifiés à date. (Stores contrôlés ; recherche officielle de similarité des marques à finaliser.)
- [x] Les collisions exactes/proches et risques sont documentés avec liens.
- [ ] Le propriétaire a enregistré une décision explicite ou accepté un risque après conseil adapté.
- [ ] Le nom retenu fonctionne en français et anglais.
- [ ] Aucun package ID définitif n'utilise `com.example`.
- [ ] `PROJECT_CONTEXT.md` et les ADR concernées reflètent le nom choisi.

## Sources minimales

- INPI : <https://data.inpi.fr/>
- EUIPO : <https://euipo.europa.eu/eSearch/>
- WIPO Global Brand Database : <https://branddb.wipo.int/>
- Google Play, Apple App Store et Microsoft Store.

Les recherches doivent être refaites le jour de la décision car la disponibilité évolue.
