# TrustCircle

**Application de messagerie sécurisée pour familles et groupes d'amis**

TrustCircle est une application de communication privée conçue pour les familles et les groupes d'amis qui se font confiance. Elle permet de partager des messages, informations, documents, calendrier et positions de manière sécurisée avec un chiffrement de bout en bout.

## 🎯 Objectif

TrustCircle répond au besoin de communication privée et sécurisée pour les cercles proches (famille, amis proches) qui souhaitent partager des informations sensibles sans compromettre leur vie privée.

## 🔐 Sécurité

- **Chiffrement de bout en bout** : Tous les messages sont chiffrés avec AES-256-GCM
- **Signatures numériques** : Vérification de l'intégrité et de l'authenticité des messages (Ed25519)
- **Échange de clés sécurisé** : X25519 pour l'échange de clés
- **Clés stockées de manière sécurisée** : Utilisation du Keychain (iOS) et EncryptedSharedPreferences (Android)
- **Aucune donnée en clair sur le serveur** : Le serveur ne peut pas lire vos messages

## ✨ Fonctionnalités

### Actuelles
- ✅ **Messagerie sécurisée** : Messages texte avec chiffrement de bout en bout
- ✅ **Groupes privés** : Création et gestion de groupes de confiance
- ✅ **Vérification de signature** : Assurance de l'authenticité des messages
- ✅ **Stockage local** : Messages sauvegardés localement pour accès rapide
- ✅ **Notifications** : Alertes pour nouveaux messages
- ✅ **Présence** : Voir qui est en ligne
- ✅ **Indicateurs de frappe** : Savoir quand quelqu'un tape

### À venir
- 📅 **Calendrier partagé** : Organiser des événements en famille
- 📍 **Partage de position** : Localisation en temps réel pour la sécurité
- 📄 **Documents** : Partage de fichiers sécurisés
- 📊 **Informations** : Tableau de bord familial avec informations importantes

## 🚀 Technologies

- **Flutter** : Framework multiplateforme
- **Chiffrement** : AES-256-GCM, X25519, Ed25519, HKDF-SHA256
- **Stockage** : SQLite avec chiffrement, Flutter Secure Storage
- **Communication** : WebSocket pour temps réel, REST API

## 📱 Plateformes

- Android
- iOS
- Web (à venir)
- Desktop (à venir)

## 🔒 Philosophie de Sécurité

TrustCircle est conçu avec la philosophie "Zero Trust" : même le serveur ne peut pas lire vos messages. Seuls les membres de votre cercle de confiance peuvent déchiffrer les messages qui leur sont destinés.

## 👥 Public Cible

- **Familles** : Communication privée entre membres de la famille
- **Groupes d'amis proches** : Partage d'informations sensibles entre amis de confiance
- **Communautés privées** : Petits groupes qui nécessitent confidentialité

## 🛠️ Développement

Voir la documentation technique dans les fichiers du projet pour plus de détails sur l'architecture et l'implémentation.
