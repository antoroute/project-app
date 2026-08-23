# Stratégie de test

Statut : cible V1
Dernière mise à jour : 2026-08-23

## Pyramide

- Unitaires : règles d'autorisation, tokens, sérialisation, machines d'état, validateurs, modèles Flutter.
- Intégration : routes Fastify + PostgreSQL réel éphémère, migrations, outbox/sync, stockage sécurisé abstrait.
- Contrat : OpenAPI, événements Socket.IO, compatibilité versions et erreurs.
- End-to-end : comptes, cercles, appareils et messages sur backend isolé.
- Plateforme : notifications, stockage, verrouillage biométrique, deep links, cycle de vie et installation/mise à jour.
- Sécurité : tests négatifs systématiques, fuzzing des parseurs, dépendances, secrets et analyse statique.
- Opérations : sauvegarde/restauration, rollback, perte réseau, redémarrage et saturation contrôlée.

## Cas prioritaires

Chaque route protégée reçoit au minimum : sans jeton, jeton expiré, refresh utilisé comme access, mauvais issuer/audience/type, non-membre, membre sans rôle, objet inexistant, corps forgé et concurrence pertinente.

Chaque enveloppe crypto reçoit : vecteur valide, bit modifié par champ, mauvaise conversation/cercle/appareil, clé révoquée, rejeu, version inconnue, taille excessive, Unicode multi-octets et ordre de champs différent.

La synchronisation couvre : timeout avant/après persistance, retry, redémarrage, déconnexion prolongée, messages concurrents, curseur ancien, doublons réseau, changement d'appareil et changement de compte.

## Matrice de plateformes

| Niveau | Android | iOS | Windows | macOS |
|---|---|---|---|---|
| Analyse/tests Dart | CI Linux | partagé | partagé | partagé |
| Build release | CI Android | runner macOS | runner Windows | runner macOS |
| Tests intégration OS | émulateur + appareil | simulateur + appareil | VM + poste | simulateur/poste |
| Parcours manuel release | appareil réel | appareil réel | Windows 10/11 | version minimale retenue |

Les versions minimales finales sont décidées dans `TC-006` après vérification des dépendances et politiques stores.

## Gates proposés

- Pull request : format, lint, analyse, unitaires, intégration concernée, scan secrets/dépendances.
- Branche principale : contrats, E2E essentiels, build Android et images backend.
- Release candidate : matrice complète, restauration, migration/rollback, performance, accessibilité et revue sécurité.
- Publication : aucune vulnérabilité critique/haute exploitable non acceptée explicitement, aucun test essentiel instable, checklist signée.

## Traçabilité

Les tests portant un invariant de sécurité citent son numéro dans leur nom ou métadonnée. Une tâche décrit les tests ajoutés et les plateformes réellement exécutées ; « non testé faute d'outil » reste un risque ouvert.
