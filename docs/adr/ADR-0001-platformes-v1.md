# ADR-0001 — Plateformes V1 et rôle du Web

Statut : Acceptée
Date : 2026-08-23
Dernière précision : 2026-08-23 (`TC-006`)

## Contexte

Le produit doit être accessible au minimum sur iOS, Android et Windows. macOS est souhaité. Un client Web poserait un chantier distinct de stockage de clés, persistance locale, récupération et protection contre les attaques propres au navigateur.

## Décision

- Android, iOS et Windows sont des cibles obligatoires de publication.
- macOS est une cible souhaitée, conditionnée par la validation technique et qualité du jalon plateforme. Son retard ne bloque pas la V1 obligatoire sans nouvelle décision produit.
- Le Web V1 est un site statique : présentation, liens vers les stores/téléchargements, support, confidentialité, conditions et demande de suppression de compte.
- Aucun contenu de messagerie ni clé privée n'est géré dans le navigateur en V1.
- Android démarre à Android 9/API 28 et cible au moins API 36 pour la publication 2026.
- iPhone et iPad démarrent à iOS/iPadOS 15 sur arm64.
- Windows démarre à Windows 11 25H2 sur x64 ; Windows 10 et Windows ARM64 ne sont pas annoncés en V1.
- macOS, s'il est annoncé, démarre à macOS 14 sur Apple Silicon arm64 ; Intel n'est pas annoncé.

## Conséquences

- Les dépendances Flutter incompatibles Windows doivent être remplacées ou abstraites.
- Les builds iOS/macOS exigent une validation sur macOS/Xcode, et Windows sur Windows.
- La V1 n'est pas annoncée sur des systèmes sortis du support de sécurité de leur éditeur.
- Le site public devient un livrable de conformité, pas seulement marketing.
- Un futur client Web exigera une nouvelle ADR et un modèle de menace dédié.
- La matrice, les dépendances incompatibles et les preuves attendues sont maintenues dans `docs/architecture/PLATFORM_COMPATIBILITY.md`.

## Réexamen

Réexaminer macOS après le prototype desktop et le Web uniquement après stabilisation du protocole V3 et du multi-appareil.
