# Périmètre V1

Statut : proposé, décision à clôturer dans `TC-005`
Dernière mise à jour : 2026-08-23

## Résultat attendu

Une personne non technique peut installer l'application, créer un compte vérifié, rejoindre un cercle privé, approuver ses appareils et échanger des messages texte chiffrés de façon fiable sur les plateformes annoncées.

## Inclus

- Inscription, vérification d'adresse électronique, connexion, rotation de session et déconnexion globale.
- Récupération d'accès avec règles explicites concernant les anciennes clés et l'historique.
- Suppression du compte depuis l'application et demande équivalente depuis le site public.
- Création de cercle, invitation, acceptation/refus, rôles minimaux et retrait d'un membre.
- Conversations texte de cercle et sous-ensembles privés clairement autorisés.
- E2EE versionné avec vérification avant affichage et gestion des changements de clés.
- Ajout, approbation, nommage et révocation d'appareils.
- File d'envoi durable, idempotence, reprise réseau et synchronisation déterministe.
- Notifications distantes au contenu générique, sans texte en clair.
- Blocage, signalement, conditions d'utilisation et contact support.
- Réglages de confidentialité essentiels et explications accessibles.
- Français et anglais ; accessibilité de base et interface adaptative.
- Android, iOS, Windows ; macOS seulement après validation du jalon plateforme.
- Site public statique : présentation, liens de téléchargement, support, confidentialité, conditions et suppression de compte.

## Exclus

- Client de messagerie dans le navigateur.
- Calendrier partagé, fichiers/documents, partage de position et appels audio/vidéo.
- Grandes communautés, canaux publics, fédération ou administration d'entreprise.
- Paiement, abonnement, publicité, marketplace ou vente de données.
- Sauvegarde serveur de clés permettant à l'opérateur de déchiffrer les messages.

## Définition fonctionnelle de « publiable »

- Aucun défaut critique ou haut ouvert sur identité, autorisation, clés ou confidentialité.
- Tous les parcours essentiels ont des tests automatisés et une preuve manuelle sur chaque plateforme annoncée.
- Une perte réseau, un redémarrage ou une répétition de requête ne perd ni ne duplique silencieusement un message.
- Sauvegarde/restauration, migration et rollback ont été exercés en staging.
- Les politiques stores correspondent exactement aux données collectées et au fonctionnement du chiffrement.
- Support, suppression de compte, signalement, politique de confidentialité et gestion d'incident sont opérationnels.
- Une bêta fermée a produit des indicateurs acceptables, définis dans la checklist de release.

## Questions à trancher dans TC-005

- Les conversations V1 sont-elles toujours rattachées à un cercle ?
- Quel modèle de rôles minimal : propriétaire/admin/membre ou propriétaire/membre ?
- Quel quorum, le cas échéant, approuve un nouveau membre ou appareil ?
- Quel historique un nouvel appareil peut-il récupérer, et par quel mécanisme ?
- Quelle conséquence exacte une récupération de compte a-t-elle sur l'historique E2EE ?
- macOS est-il un engagement de lancement ou un jalon postérieur sans blocage de la V1 ?
