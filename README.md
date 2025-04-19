# project-app

# 📦 Contexte Technique — Application de Messagerie Sécurisée Multiplateforme

## 🎯 Objectif général

Construire une **application de messagerie sécurisée multiplateforme**, avec chiffrement de bout en bout (E2EE), auto-hébergée, conteneurisée et déployée localement.

Fonctionnalités principales :
- Application mobile Flutter (iOS & Android)
- Interface Web Admin React (gestion/modération)
- Backend REST + WebSocket pour les messages
- Authentification par e-mail + mot de passe uniquement (JWT)
- Chiffrement côté client (type Telegram)
- Déploiement local sur serveur via Docker & Portainer (gratuit)
- TLS et domaines gérés par un reverse proxy NGINX externe (`kavalek.fr`)

---

## 🧱 Architecture technique

### 🔹 Frontend

- **Flutter** : application mobile (auth, chat, chiffrement, WebSocket)
- **React** : interface admin (dashboard, stats, modération)

### 🔹 Backend

- **Auth Service** (Node.js ou FastAPI)
  - Enregistrement, connexion
  - Bcrypt pour hachage des mots de passe
  - JWT pour authentification
  - Pas d’authentification OAuth (pas de Google/Apple)

- **Messaging Service** (Node.js + Socket.IO ou Python)
  - API REST : messages, conversations
  - WebSocket : échange en temps réel sécurisé (JWT)
  - Redis pour Pub/Sub des sockets
  - PostgreSQL (ou MongoDB) pour le stockage

- **Redis**
  - Pub/Sub pour événements temps réel
  - Cache pour connexions actives

- **PostgreSQL (ou MongoDB)**
  - Stockage structuré des utilisateurs, messages (chiffrés), conversations

- **NGINX (externe)**
  - Reverse proxy indépendant
  - TLS via Let’s Encrypt
  - Routage vers `/auth`, `/api`, `/socket`
  - Domaine principal : `kavalek.fr` et sous-domaines

---

## 🔐 Sécurité & chiffrement

- **Chiffrement de bout en bout (E2EE)**
  - Clés RSA 2048 bits (une par utilisateur)
  - Messages chiffrés avec AES-256, encapsulés RSA
  - Chiffrement/déchiffrement exclusivement côté client (Flutter)
  - Serveur ne stocke que des messages chiffrés
- **JWT** : utilisé pour sécuriser API et WebSocket
- **Middleware** de vérification des tokens
- **Protection API** : CORS, CSP, rate-limiting, etc.

---

## 🐳 Déploiement & infrastructure

- Tous les composants tournent dans des **conteneurs Docker**
- Déploiement local sur **un serveur personnel** géré via **Portainer (gratuit)**
- Aucun usage de Kubernetes (non prévu)
- Le reverse proxy NGINX externe gère TLS + routage domaine
- CI/CD prévu avec **GitHub Actions** :
  - Lint, test, build des images
  - Push vers Docker Hub ou GHCR
  - Déploiement automatique (Portainer webhook ou Watchtower)

---

## 📁 Arborescence projet

project-app/
├── backend/
│   ├── auth/
│   │   ├── Dockerfile
│   │   ├── index.js
│   │   ├── .env
│   │   └── README.md
│   └── messaging/
│       ├── Dockerfile
│       ├── index.js
│       ├── .env
│       └── README.md
├── frontend-admin/     # à remplir plus tard
├── frontend-mobile/    # à remplir plus tard
├── infrastructure/
│   ├── docker-compose-infra.yml
│   ├── Makefile
│   ├── postgres/
│   │   └── init.sql
│   └── redis/
│       └── redis.conf
├── app/
│   ├── docker-compose-app.yml
│   ├── Makefile
│   ├── nginx/
│   │   ├── nginx.conf
│   │   └── site.conf
│   └── certbot/
│       └── README.md
├── scripts/
│   ├── deploy_infra.sh
│   ├── deploy_app.sh
│   └── teardown.sh
└── README.md
