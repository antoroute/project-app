# Roadmap de développement vers la V1

Statut : plan directeur initial
Dernière mise à jour : 2026-08-24

## Mode d'emploi

Les identifiants sont stables. Une tâche est développée à partir d'une fiche dans `docs/tasks/`; seules `TC-001` à `TC-008` ont leur fiche détaillée à ce stade. Avant le démarrage d'une phase, créer/raffiner les fiches de cette phase à partir des constats les plus récents.

Statuts utilisés : `À faire`, `Prête`, `En cours`, `Terminée`, `Bloquée`. Une phase ne passe sa porte de sortie que si les preuves sont attachées aux tâches et les risques critiques fermés.

## Phase 0 — Cadre et filet de sécurité

Objectif : connaître la cible et rendre tout travail ultérieur récupérable.

| ID | Tâche | Dépend de | Statut |
|---|---|---|---|
| TC-001 | Valider le nom, les stores, marques et domaines | — | En cours — CircleHaven choisi, clearance/réservations externes |
| TC-002 | Inventorier la VM de production en lecture seule | accès assaini | Terminée — écarts ouverts |
| TC-003 | Créer une sauvegarde chiffrée et prouver la restauration | TC-002 | Terminée — données historiques abandonnées |
| TC-004 | Créer un staging totalement séparé | TC-002, TC-003 | Terminée — backend local |
| TC-005 | Geler le périmètre et les non-objectifs V1 | — | Terminée |
| TC-006 | Décider les versions OS minimales et la matrice appareils | TC-005 | Terminée — matrice acceptée, preuves reportées aux plateformes |
| TC-007 | Créer le contexte, les ADR, prompts et conventions IA | — | Terminée |
| TC-008 | Établir le modèle de menace et les invariants initiaux | TC-007 | Terminée — baseline |
| TC-009 | Documenter le fonctionnement complet et la cryptographie actuelle | TC-007, TC-008 | Terminée |

Porte de sortie : nom décidé, V1 acceptée, inventaire production assaini, sort des données historiques décidé, staging isolé et décisions plateformes enregistrées.

La porte de sortie technique de Phase 0 est satisfaite : le nom est décidé sous réserve de clearance, le périmètre et les plateformes sont acceptés, l'infrastructure est inventoriée, les anciennes données ont été abandonnées et le staging est isolé. `TC-001` reste ouverte en parallèle pour ses recherches officielles et réservations externes ; elle bloque l'identité release et la publication, mais pas les travaux de sécurité de Phase 1. Les builds et probes des OS relèvent des tâches `TC-701` à `TC-707` et ne sont pas présentés comme déjà réussis.

## Phase 1 — Fermer les vulnérabilités critiques

Objectif : empêcher l'usurpation, l'accès croisé et l'enregistrement illégitime de clés avant toute extension fonctionnelle.

| ID | Tâche | Dépend de | Statut |
|---|---|---|---|
| TC-101 | Faire échouer les services si un secret/config critique manque | TC-004 | Terminée |
| TC-102 | Séparer strictement access/refresh JWT et valider toutes les claims | TC-101 | Terminée — Ed25519 déployé |
| TC-103 | Dériver l'identité serveur et supprimer les `userId` faisant autorité côté client | TC-102 | Terminée |
| TC-104 | Centraliser la matrice ACL cercle/conversation/rôle | TC-103 | Prête |
| TC-105 | Corriger l'atomicité des contrôles et écritures | TC-104 | À faire |
| TC-106 | Sécuriser preuve, approbation, rotation et révocation des clés d'appareil | TC-104 | À faire |
| TC-107 | Borner et valider tous les payloads, identifiants et tailles | TC-103 | À faire |
| TC-108 | Durcir CORS, rate limits, proxy trust et WebSocket | TC-102, TC-107 | À faire |
| TC-109 | Retirer le faux secret partagé de l'application publique | TC-101 | À faire |
| TC-110 | Mettre à jour les dépendances vulnérables avec tests | TC-111 | À faire |
| TC-111 | Créer les tests négatifs auth/ACL/keys et PostgreSQL d'intégration | TC-004 | À faire |
| TC-114 | Interdire affichage, cache et notification avant authentification du message | TC-103 | En cours |
| TC-112 | Revue de sécurité de fermeture P1 | TC-101 à TC-111, TC-114 | À faire |
| TC-113 | Exposer le staging par TLS et accès restreint après fermeture P1 | TC-112 | À faire |

Porte de sortie : tests d'usurpation et accès croisé tous négatifs, aucun secret par défaut/embarqué, aucune vulnérabilité critique/haute exploitable acceptée silencieusement.

## Phase 2 — Données et exploitation reproductibles

| ID | Tâche | Dépend de |
|---|---|---|
| TC-201 | Choisir l'outil de migration et créer une baseline | TC-002, TC-004 |
| TC-202 | Réconcilier le schéma de production avec la baseline | TC-201 |
| TC-203 | Séparer comptes DB, secrets et privilèges par service | TC-201 |
| TC-204 | Durcir images/conteneurs, utilisateurs, systèmes de fichiers et ressources | TC-004 |
| TC-205 | Retirer Redis ou l'intégrer correctement sur réseau privé | TC-002 |
| TC-206 | Ajouter logs structurés, corrélation et redaction | TC-112 |
| TC-207 | Ajouter health/readiness checks et métriques minimales | TC-206 |
| TC-208 | Automatiser sauvegardes, alertes et tests de restauration | TC-003, TC-201 |
| TC-209 | Construire/publier des images immuables avec provenance en CI | TC-204 |
| TC-210 | Exercer déploiement, migration et rollback en staging | TC-202 à TC-209 |

Porte de sortie : environnement reproductible, migrations versionnées, restauration et rollback prouvés, observabilité sans contenu sensible.

## Phase 3 — Protocole E2EE V3 et multi-appareil

| ID | Tâche | Dépend de |
|---|---|---|
| TC-301 | Comparer/prototyper MLS ou alternatives et accepter ADR-0003 | TC-006, TC-112 |
| TC-302 | Écrire la spécification V3 indépendante du code | TC-301 |
| TC-303 | Spécifier identité, preuve et confiance des appareils | TC-302 |
| TC-304 | Spécifier changements de membres, époques, rotation et révocation | TC-302 |
| TC-305 | Définir encodage canonique, domaine signé et limites | TC-302 |
| TC-306 | Corriger stockage sécurisé et espaces de noms par compte/appareil | TC-303 |
| TC-307 | Concevoir coexistence et migration V2 → V3 | TC-302 à TC-306 |
| TC-308 | Produire vecteurs de test interopérables | TC-305 |
| TC-309 | Ajouter tests négatifs, rejoués et fuzzing parseurs | TC-308 |
| TC-310 | Adapter le relayage/persistance backend V3 sans accès au clair | TC-307 |
| TC-311 | Implémenter V3 et le cycle multi-appareil côté Flutter | TC-306 à TC-310 |
| TC-312 | Faire auditer le protocole et corriger les constats | TC-311 |

Porte de sortie : protocole spécifié, migrable, testé sur toutes les plateformes et revu indépendamment ; affichage uniquement après vérification.

## Phase 4 — Comptes et récupération

| ID | Tâche | Dépend de |
|---|---|---|
| TC-401 | Vérification d'e-mail et anti-abus d'inscription | TC-112 |
| TC-402 | Réinitialisation de mot de passe sûre | TC-401 |
| TC-403 | Lister/révoquer sessions et appareils | TC-303, TC-402 |
| TC-404 | Implémenter le modèle de récupération E2EE décidé | TC-303, TC-304 |
| TC-405 | Suppression de compte backend et politique de rétention | TC-201, TC-403 |
| TC-406 | Endpoint/page Web de demande de suppression | TC-405 |
| TC-407 | Finaliser les écrans compte, sécurité et conséquences E2EE | TC-401 à TC-406 |
| TC-408 | Tester abus, énumération, expiration et concurrence | TC-407 |

Porte de sortie : cycle de compte complet, conséquences cryptographiques compréhensibles, suppression démontrée.

## Phase 5 — Messagerie et synchronisation fiables

| ID | Tâche | Dépend de |
|---|---|---|
| TC-501 | Ajouter identifiant idempotent et curseur serveur durable | TC-201, TC-310 |
| TC-502 | Remplacer la queue par une outbox typée/versionnée | TC-306, TC-501 |
| TC-503 | Rendre l'envoi backend atomique et idempotent | TC-501 |
| TC-504 | Concevoir l'API de rattrapage/synchronisation | TC-501, TC-503 |
| TC-505 | Fiabiliser ACK, reconnexion et reprise Socket.IO | TC-504 |
| TC-506 | Garantir ordre, déduplication et états convergents | TC-502 à TC-505 |
| TC-507 | Exposer les états envoi/échec/retry sans perte silencieuse | TC-506 |
| TC-508 | Tests chaos réseau, redémarrage et concurrence | TC-507 |
| TC-509 | Gérer tokens push et notifications distantes génériques | TC-403, TC-504 |
| TC-510 | Borner présence/frappe et leurs fuites de métadonnées | TC-505 |

Porte de sortie : tests offline/retry passent, aucun doublon/perte silencieuse, notifications sans contenu.

## Phase 6 — Produit Flutter et expérience utilisateur

| ID | Tâche | Dépend de |
|---|---|---|
| TC-601 | Décomposer le provider monolithique et clarifier les états | TC-507 |
| TC-602 | Séparer domaines, repositories, transports et stockage | TC-601 |
| TC-603 | Créer navigation et layouts adaptatifs mobile/desktop | TC-602 |
| TC-604 | Internationaliser entièrement français/anglais | TC-603 |
| TC-605 | Corriger accessibilité clavier, lecteur d'écran, contraste et tailles | TC-603 |
| TC-606 | Refaire onboarding compte/cercle/appareil | TC-407, TC-603 |
| TC-607 | Finaliser UX cercles, invitations, rôles et erreurs | TC-606 |
| TC-608 | Créer le centre appareils/sécurité | TC-403, TC-606 |
| TC-609 | Finaliser états de messages, vérification et récupération d'erreur | TC-507, TC-603 |
| TC-610 | Paramètres confidentialité, notifications et suppression | TC-405, TC-509 |
| TC-611 | Stabiliser design system, icônes et visuels release | TC-604 à TC-610 |

Porte de sortie : parcours V1 utilisables sans connaissance technique, accessibles et adaptatifs.

## Phase 7 — Adaptation des plateformes

| ID | Tâche | Dépend de |
|---|---|---|
| TC-701 | Android : identité, signature release, permissions et AAB | TC-001, TC-006, TC-611 |
| TC-702 | iOS : bundle, signature, capabilities, APNs et archive | TC-001, TC-006, TC-611 |
| TC-703 | Windows : stockage SQLite/secure storage compatible | TC-006, TC-306, TC-602 |
| TC-704 | Windows : invitation sans dépendance scanner incompatible | TC-607, TC-703 |
| TC-705 | Windows : notifications, MSIX, signature et mises à jour | TC-509, TC-703, TC-704 |
| TC-706 | macOS : entitlements, stockage, notifications, signature/notarisation | TC-006, TC-611, TC-703 |
| TC-707 | Automatiser la matrice build/test des plateformes annoncées | TC-701 à TC-706 |

Porte de sortie : artefact release installable, signé et testé sur chaque plateforme annoncée.

## Phase 8 — Conformité, audit et lancement

| ID | Tâche | Dépend de |
|---|---|---|
| TC-801 | Relever les exigences stores/SDK/crypto effectives | TC-001, TC-006 |
| TC-802 | Publier landing, téléchargements, support, légal et suppression | TC-406, TC-801 |
| TC-803 | Finaliser conditions, confidentialité, data map et formulaires stores | TC-802 |
| TC-804 | Opérationnaliser blocage, signalement et traitement des abus | TC-607, TC-803 |
| TC-805 | Finaliser CI, gates, SBOM, provenance et scans | TC-707 |
| TC-806 | Tester performance, charge, quotas et capacité VM | TC-207, TC-505 |
| TC-807 | Auditer accessibilité, traductions et UX multi-plateforme | TC-611, TC-707 |
| TC-808 | Réaliser pentest applicatif/infrastructure et corriger | TC-805, TC-806 |
| TC-809 | Clôturer l'audit cryptographique | TC-312 |
| TC-810 | Lancer une bêta fermée instrumentée avec consentement minimal | TC-803 à TC-809 |
| TC-811 | Corriger les constats bêta et préparer les dossiers stores | TC-810 |
| TC-812 | Publier progressivement, surveiller et savoir retirer/rollback | TC-811 |

Porte de sortie : checklists signées, audits clos, bêta acceptable et publication progressive surveillée.

## Phase 9 — Monétisation après validation d'usage

| ID | Tâche | Dépend de |
|---|---|---|
| TC-901 | Recherche utilisateurs et test de disposition à payer | TC-810 |
| TC-902 | Décider offre gratuite/premium sans sécurité à deux vitesses | TC-901 |
| TC-903 | Concevoir droits, quotas et restauration d'achat | TC-902 |
| TC-904 | Intégrer facturation stores et validation serveur des reçus | TC-903 |
| TC-905 | Créer UX abonnement, essai, annulation et transparence prix | TC-904 |
| TC-906 | Définir familles, changements de plateforme et support paiement | TC-904 |
| TC-907 | Mesurer conversion/churn sans contenu ni profilage invasif | TC-905 |
| TC-908 | Déployer l'offre progressivement et réévaluer | TC-906, TC-907 |

Porte de sortie : valeur payante validée, conformité facturation, aucun affaiblissement des fonctions de sécurité gratuites.

## Chemin critique

`TC-002 → TC-003 → TC-004 → Phase 1 → TC-201/TC-210 → TC-301/TC-312 → TC-501/TC-508 → plateformes → audits → bêta → publication`.

Le nom (`TC-001`) et le périmètre (`TC-005`/`TC-006`) avancent en parallèle. La monétisation ne doit pas détourner ce chemin critique avant une bêta fiable.
