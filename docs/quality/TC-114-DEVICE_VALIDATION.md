# Validation appareils — TC-114

Statut : à exécuter sur Android et Windows
Dernière mise à jour : 2026-08-25

## Objectif

Vérifier que la barrière `verify-before-use` reste imperceptible sur les plateformes disponibles. Cette procédure n'utilise ni secret partagé dans un rapport, ni contenu réel : employer des comptes et messages de test.

Budget proposé à valider par le mainteneur :

- clé de message déjà en cache : p95 de `message_receive_verified_total` inférieur ou égal à 100 ms ;
- nouvelle clé de message, annuaire déjà local : p95 inférieur ou égal à 250 ms ;
- aucune image figée, frappe bloquée ou bulle contenant du texte avant la fin de la mesure ;
- aucun appel réseau supplémentaire quand `KeyDirectoryService` possède déjà le cercle en cache.

Le premier accès à un cercle sans annuaire local est mesuré séparément : il inclut le réseau et ne doit pas être confondu avec le coût cryptographique.

## Jeu de test

1. Utiliser exclusivement le staging et deux comptes de test.
2. Préparer au moins 50 nouveaux messages texte, dont accents et emoji.
3. Garder l'annuaire du cercle en cache pour isoler la cryptographie.
4. Ne jamais copier `.env`, jetons, enveloppes ou contenu des messages dans le rapport.

## Android

Depuis `frontend-mobile/flutter_message_app`, avec l'appareil visible par `flutter devices` :

```bash
flutter run -d <identifiant-android>
```

Ouvrir la conversation une première fois avec les nouveaux messages, puis une seconde fois pour exercer le cache persistant. Dans la sortie debug, relever uniquement les lignes agrégées du rapport pour :

- `message_signature_verify` ;
- `message_decrypt_verified_pipeline` ;
- `message_decrypt_verified_cached` ;
- `message_receive_verified_total`.

## Windows 11

Dans PowerShell, depuis le même dossier :

```powershell
flutter run -d windows
```

Répéter le scénario Android et relever les mêmes agrégats.

## Vérifications de sécurité manuelles

- aucun texte de message n'apparaît dans les logs Flutter ;
- un message valide affiche directement son texte avec `signatureValid == true` ;
- une enveloppe altérée par le test automatisé ne crée ni bulle, ni notification, ni cache de texte ;
- après fermeture/réouverture, une clé persistante n'est utilisée qu'après une nouvelle vérification Ed25519 de l'enveloppe.

## Preuve à reporter dans TC-114

Pour chaque plateforme : version OS, type d'appareil/CPU, nombre de mesures, médiane et p95 des quatre opérations, résultat UX et anomalies. Ne fournir aucune donnée utilisateur, aucun identifiant réel et aucun extrait de message.
