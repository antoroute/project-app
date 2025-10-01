-- ===== init.sql (v2, clean) =====
-- Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =========================
-- Utilisateurs & Appareils
-- =========================
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  username TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Chaque utilisateur peut avoir plusieurs appareils.
-- device_id est un identifiant stable côté client (ex: "U#A1").
CREATE TABLE IF NOT EXISTS devices (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id TEXT  NOT NULL,
  display_name TEXT,
  platform TEXT,              -- ios|android|desktop|web...
  status TEXT NOT NULL DEFAULT 'active',  -- active|revoked
  key_version INT NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ,
  PRIMARY KEY (user_id, device_id)
);

-- ========
-- Groupes
-- ========
CREATE TABLE IF NOT EXISTS groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id UUID REFERENCES users(id),
  name TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Appartenance des utilisateurs aux groupes
CREATE TABLE IF NOT EXISTS user_groups (
  user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member', -- member|admin
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, group_id)
);

-- Clés publiques par (groupe, utilisateur, appareil)
-- pk_* en BYTEA (32 octets). Checks de taille pour robustesse.
CREATE TABLE IF NOT EXISTS group_device_keys (
  group_id  UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  pk_sig    BYTEA NOT NULL,   -- Ed25519 public key (32B)
  pk_kem    BYTEA NOT NULL,   -- X25519 public key (32B)
  key_version INT NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'active', -- active|revoked
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ,
  PRIMARY KEY (group_id, user_id, device_id),
  CONSTRAINT chk_pk_sig_len CHECK (octet_length(pk_sig) = 32),
  CONSTRAINT chk_pk_kem_len CHECK (octet_length(pk_kem) = 32)
);

-- (Optionnel) Workflow d’adhésion si tu veux le garder,
-- nettoyé des champs d’anciennes clés RSA :
CREATE TABLE IF NOT EXISTS join_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','rejected')),
  handled_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS join_request_votes (
  request_id UUID NOT NULL REFERENCES join_requests(id) ON DELETE CASCADE,
  voter_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  vote BOOLEAN NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (request_id, voter_id)
);

-- ==========================
-- Conversations & Messages
-- ==========================
CREATE TYPE conversation_type AS ENUM ('private','subset');

CREATE TABLE IF NOT EXISTS conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  type conversation_type NOT NULL,
  creator_id UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS conversation_users (
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_read_at TIMESTAMPTZ,
  PRIMARY KEY (conversation_id, user_id)
);

-- Messages v2 (X25519 + Ed25519 + AES-GCM, fan-out par appareil)
-- On stocke uniquement du chiffré et des métadonnées.
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),       -- identifiant interne
  message_id UUID NOT NULL,                            -- id fourni par le client (anti-replay)
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_user_id UUID NOT NULL REFERENCES users(id),
  sender_device_id TEXT NOT NULL,
  v SMALLINT NOT NULL DEFAULT 2,                       -- version crypto
  alg JSONB NOT NULL DEFAULT '{"kem":"X25519","kdf":"HKDF-SHA256","aead":"AES-256-GCM","sig":"Ed25519"}',
  sent_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  sender_eph_pub BYTEA NOT NULL,       -- 32B
  iv BYTEA NOT NULL,                   -- 12B
  ciphertext BYTEA NOT NULL,           -- blob chiffré (stockage en bytea)
  wrapped_keys JSONB NOT NULL,         -- [{userId, deviceId, wrap (base64), nonce (base64)}]
  sig BYTEA NOT NULL,                  -- 64B Ed25519

  deleted_at TIMESTAMPTZ,
  CONSTRAINT uq_message_id UNIQUE (message_id),
  CONSTRAINT chk_sender_eph_pub_len CHECK (octet_length(sender_eph_pub) = 32),
  CONSTRAINT chk_iv_len CHECK (octet_length(iv) = 12),
  CONSTRAINT chk_sig_len CHECK (octet_length(sig) = 64)
);

-- Index utiles
CREATE INDEX IF NOT EXISTS idx_messages_conv_sent_at ON messages (conversation_id, sent_at DESC);

-- ==================
-- Auth & Notifications
-- ==================
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT UNIQUE NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);

CREATE TABLE IF NOT EXISTS notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  payload JSONB NOT NULL,
  is_read BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ===== Fin init v2 =====
