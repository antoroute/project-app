# TC-707 — Automatiser la matrice Flutter

Statut : À faire
Priorité : P0 release
Décision : mainteneur
Dépendances : TC-701 à TC-706 selon plateformes annoncées

## Objectif

Rendre reproductibles les analyses, tests et builds Android/iOS/Windows ainsi que macOS s'il est annoncé, avec toolchain figée et preuves téléchargeables.

## Travail

- Épingler Flutter 3.44.7 ou sa version de remplacement acceptée et enregistrer Dart, SDK, Xcode, Java, Gradle et Visual Studio.
- Utiliser des runners explicites Ubuntu 24.04, Windows 2025 et macOS 26 ; ne pas dépendre de `latest`.
- Séparer jobs rapides de PR, builds de branche principale et matrice complète de release candidate.
- Mettre en cache seulement les dépendances vérifiables, sans clé de signature dans les artifacts/logs.
- Produire artifacts à durée courte, hashes, résultats de tests et SBOM ; protéger les workflows de release.
- Exécuter émulateurs/simulateurs minimum et courant, puis attacher les preuves manuelles d'appareils.

## Critères d'acceptation

- [ ] Une révision propre reproduit chaque build obligatoire sans fichier local caché.
- [ ] Format, analyse, tests et builds bloquent la fusion selon `TEST_STRATEGY.md`.
- [ ] Les versions de toolchain sont affichées sans secret et ne flottent pas.
- [ ] Les artifacts ne contiennent aucun `.env`, secret partagé, profil privé ou donnée de test réelle.
- [ ] Un échec d'une plateforme annoncée bloque la release candidate.

## Coût et sécurité

Le dépôt public utilise les runners standards sans facturation à la minute annoncée par GitHub. Les permissions Actions sont minimales, les actions tierces sont épinglées par SHA lors de l'implémentation et les workflows de pull requests non fiables n'accèdent à aucun secret.
