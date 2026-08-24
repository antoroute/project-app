# TC-114 — Vérifier tout message avant utilisation du texte clair

Statut : Prête
Priorité : P0 sécurité
Décision : mainteneur
Dépendances : TC-103

## Contexte et problème

Le chemin `decryptFast` retourne du texte clair sans vérification Ed25519. `ConversationProvider` peut afficher ce texte, l'insérer dans les caches et déclencher une notification avant la vérification complète en arrière-plan. Le chemin normal retourne lui aussi le texte avec un booléen de signature faux au lieu de rejeter.

Ce comportement viole les invariants 16 à 18 et permet à un contenu non authentifié d'atteindre l'utilisateur. Des journaux de debug peuvent en outre contenir un extrait de texte clair.

## Objectif mesurable

Garantir qu'aucun texte de message n'est affiché, notifié, indexé, journalisé ou persisté comme valide tant que l'enveloppe, l'identité de l'expéditeur, la signature et le tag AEAD n'ont pas tous été validés.

Conserver une expérience fluide : aucun aller-retour réseau supplémentaire sur le chemin nominal quand la clé publique validée est en cache, calcul hors thread UI et mesure de latence sur appareils cibles.

## Périmètre

- `MessageCipherV2.decrypt`, `decryptFast` et isolates cryptographiques.
- `ConversationProvider`, caches, stockage, notifications et logs associés.
- États UI transitoires et erreurs d'authenticité.
- Tests négatifs et benchmarks Android/Windows disponibles.

## Hors périmètre

- Concevoir le protocole V3 ou modifier silencieusement le format V2.
- Résoudre à lui seul la confiance initiale dans l'annuaire de clés (`TC-106`/`TC-303`).
- Chiffrer la base locale et corriger sa clé maître (`TC-306`).

## Critères d'acceptation

- [ ] Une signature absente, invalide ou invérifiable bloque toute remise du texte à l'UI.
- [ ] Un tag, un wrap, un destinataire, une version ou un contexte invalide est rejeté sans cache ni notification.
- [ ] Les chemins temps réel, REST, cache mémoire et cache persistant appliquent la même barrière.
- [ ] Aucun extrait de texte clair n'est écrit dans les logs, y compris en debug.
- [ ] Une clé publique validée peut être mise en cache sans contourner la vérification par message.
- [ ] Les calculs coûteux ne bloquent pas le thread UI.
- [ ] La latence p50/p95 de réception et d'ouverture est mesurée sur Android et Windows ; l'objectif UX est documenté et accepté.
- [ ] Les erreurs sont génériques côté utilisateur et détaillées sans secret dans la télémétrie locale autorisée.

## Tests et preuves attendues

- tests unitaires : signature altérée, mauvais expéditeur/appareil, mauvais tag, mauvais nonce, mauvais wrap, clé absente ;
- test d'intégration : événement Socket.IO forgé ne produit ni bulle, ni notification, ni entrée déchiffrée ;
- test de régression : message valide reçu depuis REST et Socket.IO ;
- instrumentation démontrant que l'événement d'affichage survient après succès de vérification ;
- benchmark avant/après sur Android et Windows.

## Risques, migration et rollback

Le correctif peut révéler des enveloppes historiques invalides auparavant tolérées. Elles doivent apparaître comme indisponibles/non authentifiables, jamais comme texte fiable. Garder la lecture du format V2, mais ne pas rétablir le chemin non vérifié en rollback ; corriger plutôt la performance ou la récupération de clé.

## Documentation à mettre à jour

- `docs/security/CRYPTOGRAPHY_V2.md`
- `docs/architecture/FUNCTIONAL_REFERENCE.md`
- `docs/architecture/TRACEABILITY.md`
- `docs/security/SECURITY_INVARIANTS.md` si une clarification est nécessaire

## Décisions humaines nécessaires

Valider le budget de latence p95 par plateforme et l'état UI très bref à montrer lorsque la vérification dépasse ce budget.
