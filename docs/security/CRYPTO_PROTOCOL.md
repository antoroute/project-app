# Protocole cryptographique

Statut : V2 observée, V3 à décider
Dernière mise à jour : 2026-08-23

## État V2 observé

Le client emploie X25519 pour établir des secrets avec les clés publiques d'appareils, HKDF-SHA256 pour dériver des clés, AES-256-GCM pour le contenu/enveloppement et Ed25519 pour signer. Une clé éphémère d'expéditeur est produite par message et des clés de message sont enveloppées pour les appareils destinataires.

Cette liste d'algorithmes ne suffit pas à démontrer un protocole sûr. La sérialisation canonique, le domaine signé, l'approbation des clés, la rotation, l'historique, la révocation, la protection contre rejeu et le traitement multi-appareil doivent être spécifiés ensemble.

## Limites connues

- Des clés destinataires statiques peuvent permettre de déchiffrer d'anciens messages capturés si leur clé privée est compromise plus tard.
- Aucune post-compromise security démontrée ne renouvelle automatiquement la confiance après compromission.
- Le format est lié à l'implémentation Dart et certaines conversions sont ambiguës entre texte et octets.
- La vérification peut intervenir après l'affichage dans le flux client actuel.
- Le cycle de confiance d'un nouvel appareil est incomplet.
- Aucun ensemble de vecteurs de test interopérables ni audit indépendant n'est présent.

## Exigences pour V3

- Spécification indépendante de l'implémentation, version et domaine explicites.
- Encodage canonique binaire ou JSON canonique normé, avec tailles/limites définies.
- Authentification de tous les champs contextuels et protection anti-rejeu.
- Cycle complet : création d'identité, ajout d'appareil, distribution, rotation, révocation, perte et récupération.
- Définition exacte de l'historique accessible à un nouvel appareil.
- Forward secrecy et post-compromise security comme objectifs évalués, pas comme slogans.
- Vecteurs de test multi-implémentations, tests négatifs et fuzzing des parseurs.
- Plan de coexistence/migration des enveloppes V2 sans déchiffrement serveur.
- Revue par un spécialiste indépendant avant la promesse publique.

## Décision ouverte

`ADR-0003` compare l'adoption d'un standard de messagerie de groupe, notamment MLS via une bibliothèque mûre, avec un protocole interne V3 minimal. Le choix dépendra de la maturité des bibliothèques Flutter/desktop, de l'interopérabilité, du coût de migration et de la capacité à auditer/maintenir la solution.

Tant que cette décision n'est pas clôturée, ne pas étendre le protocole V2 à de nouveaux types de contenu et ne pas publier de revendication de sécurité avancée.
