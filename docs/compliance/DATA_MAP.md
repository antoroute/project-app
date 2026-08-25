# Cartographie des données

Statut : brouillon technique, à compléter avec conseil juridique
Dernière mise à jour : 2026-08-25

| Catégorie | Exemples | Localisation | Lisible serveur | Finalité | Rétention cible |
|---|---|---|---|---|---|
| Compte | e-mail, nom, hash de mot de passe | PostgreSQL auth | oui | créer/sécuriser le compte | à définir |
| Session | hash refresh, appareil, dates/IP si journalisées | PostgreSQL/logs | oui | authentification/sécurité | à définir, minimale |
| Graphe social | cercles, membres, rôles, conversations | PostgreSQL messaging | oui | fournir le service | durée du compte/cercle + règles à définir |
| Clés publiques | identité/appareil, versions, révocation | PostgreSQL + clients | oui, publiques | acheminer/vérifier E2EE | historique de sécurité à définir |
| Enrôlement appareil | nom, plateforme, clé publique, état, empreinte de grant, challenge et résultat | PostgreSQL partagé | oui, sauf secrets bruts absents | réauthentification, preuve de possession et sécurité du compte | grants/challenges : 7 jours après consommation/expiration ; registre : historique de sécurité à définir |
| Contenu message | texte en clair | appareils destinataires | non attendu | communication | local jusqu'à suppression/retrait du compte |
| Enveloppe E2EE | ciphertext, wraps, signature, horodatage | PostgreSQL + clients | opaque sauf métadonnées | livraison/synchronisation | 90 jours serveur, sauf suppression antérieure |
| Notifications | type, état, payload minimal | PostgreSQL/push | oui si présent | alerter sans contenu | courte, à définir |
| Support/signalement | contact, motif, preuve choisie par utilisateur | système support futur | oui selon soumission | sécurité/modération | à définir |
| Télémétrie | erreurs, version, plateforme, identifiant pseudonyme éventuel | outil futur | oui | fiabilité/sécurité | minimale, à décider avant collecte |
| Sauvegardes | copie des données serveur | stockage chiffré | oui pour métadonnées | reprise | rotation à définir |

## Principes

- Minimisation, finalité et durée sont décidées avant collecte.
- Aucun contenu E2EE, clé privée, jeton ou mot de passe n'entre dans analytics/logs/crash reports.
- Les données de production ne sont pas utilisées comme fixtures de développement.
- Les fournisseurs, régions d'hébergement, transferts, sous-traitants et bases légales sont documentés avant publication.
- Les demandes d'accès/suppression ont un processus vérifiable et expliquent les limites des copies déjà reçues par d'autres participants.

## Questions ouvertes

- Quelles métadonnées réseau et de sécurité sont journalisées par le proxy, Docker et les services ?
- Quel fournisseur envoie vérification e-mail, récupération et push, dans quelles régions ?
- Les signalements contiendront-ils un message choisi par l'utilisateur et comment sera-t-il déchiffré/transmis ?
- Quelles durées pour comptes supprimés, refresh tokens, enveloppes, journaux, notifications et sauvegardes ?
- Quel mécanisme d'export est compatible avec l'identité et l'E2EE ?

Ce document décrit la technique et ne remplace pas une analyse juridique/RGPD.
