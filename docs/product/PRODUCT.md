# Vision produit

Statut : vision V1 acceptée
Dernière mise à jour : 2026-08-24

## Problème

Les familles et petits groupes d'amis utilisent des outils généralistes dont les règles, les données et la complexité ne sont pas toujours adaptées à un cercle privé durable. Ils ont besoin d'un espace simple où l'appartenance est explicite, les conversations restent fiables sur plusieurs appareils et le contenu n'est pas lisible par l'opérateur.

## Proposition de valeur

CircleHaven — Trust Circle fournit des cercles privés, une messagerie texte chiffrée de bout en bout, une validation claire des nouveaux membres/appareils et une expérience cohérente sur téléphone et ordinateur.

La sécurité doit rester compréhensible : l'application explique ce qui est protégé, ce qui reste visible sous forme de métadonnées, et ce qui arrive lors d'une perte d'appareil ou de compte.

## Public initial

- Familles souhaitant isoler leurs conversations de services publicitaires.
- Groupes d'amis proches qui veulent un espace privé et stable.
- Petits cercles non professionnels ayant besoin d'un onboarding guidé et non technique.

Les entreprises, établissements scolaires, équipes réglementées et grandes communautés ne sont pas la cible V1.

## Principes produit

- La sécurité fondamentale n'est jamais payante.
- La fiabilité et la récupération priment sur le nombre de fonctionnalités.
- Toute action sensible indique sa conséquence : ajout d'appareil, révocation, perte de clés, suppression de compte.
- Les paramètres protecteurs sont activés par défaut.
- Aucun message marketing ne promet une propriété cryptographique non démontrée.
- Une personne doit pouvoir exporter ou supprimer les données auxquelles elle a droit sans passer par un parcours caché.

## Parcours essentiels

1. Créer et vérifier un compte, se connecter et récupérer l'accès de façon sûre.
2. Créer un cercle ou le rejoindre par une invitation contrôlée.
3. Ajouter ou révoquer un appareil avec validation explicite.
4. Envoyer, recevoir et relire des messages texte, y compris après une coupure réseau.
5. Comprendre l'état d'envoi et les erreurs sans perte silencieuse.
6. Bloquer/signaler un utilisateur ou contenu, contacter le support et supprimer son compte.

Les décisions détaillées, personas et résultats d'échec acceptables sont dans `V1_DECISIONS.md`.

## Indicateurs de validation

Les mesures doivent être définies dans une ADR analytics respectueuse de la vie privée avant instrumentation.

- Activation : compte vérifié, premier cercle rejoint/créé, premier message confirmé.
- Fiabilité : taux d'envoi final réussi, doublons, échecs de déchiffrement, délai de synchronisation.
- Usage : rétention D7/D30 par cohorte, cercles actifs, utilisateurs actifs par cercle.
- Sécurité : appareils révoqués, échecs de validation, incidents d'autorisation, délai de correction.
- Qualité : crash-free sessions par plateforme, démarrages réussis, tickets support par version.

Ne jamais collecter le contenu des messages, les clés ou des identifiants inutiles pour calculer ces indicateurs.

## Modèle économique envisagé

La V1 valide l'usage avant de monétiser. Une évolution freemium peut proposer des options de confort ou de capacité — historique étendu, personnalisation, sauvegarde chiffrée contrôlée par l'utilisateur, davantage d'appareils ou services familiaux — sans réduire le chiffrement, la vérification, le blocage, la suppression ou la sécurité du compte pour les utilisateurs gratuits.
