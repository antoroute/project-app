-- infrastructure/postgres/init.sql  (V2)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Utilisateurs
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  password TEXT NOT NULL,
  username TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  -- plus de public_key globale (RSA) en v2
);

-- Groupes (avec leurs clés communes)
CREATE TABLE IF NOT EXISTS groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id UUID REFERENCES users(id),
  name TEXT UNIQUE NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Clés du groupe (Ed25519 pour sig + X25519 pour ECDH)
CREATE TABLE IF NOT EXISTS group_keys (
  group_id UUID PRIMARY KEY REFERENCES groups(id) ON DELETE CASCADE,
  pk_sig   BYTEA NOT NULL,        -- 32B Ed25519 public
  key_version INT NOT NULL DEFAULT 1,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Appartenance utilisateur↔groupe (sans clé RSA)
CREATE TABLE IF NOT EXISTS user_groups (
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, group_id)
);

-- Requêtes d’adhésion (incluent désormais les clés publiques du PREMIER appareil)
CREATE TABLE IF NOT EXISTS join_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Clés publiques v2 pour l'appareil initial
  device_id TEXT NOT NULL,
  pk_sig BYTEA NOT NULL,  -- 32B Ed25519 public
  pk_kem BYTEA NOT NULL,  -- 32B X25519 public
  status TEXT NOT NULL CHECK (status IN ('pending','accepted','rejected')) DEFAULT 'pending',
  handled_by UUID REFERENCES users(id),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS join_request_votes (
  request_id UUID NOT NULL REFERENCES join_requests(id) ON DELETE CASCADE,
  voter_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  vote BOOLEAN NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (request_id, voter_id)
);

-- Clés publiques par GROUPE, par UTILISATEUR, par APPAREIL
CREATE TABLE IF NOT EXISTS group_device_keys (
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  pk_sig   BYTEA NOT NULL,        -- 32B
  pk_kem   BYTEA NOT NULL,        -- 32B
  key_version INT NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'active', -- active|revoked
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at TIMESTAMP,
  PRIMARY KEY (group_id, user_id, device_id)
);

-- Conversations
CREATE TABLE IF NOT EXISTS conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('private','subset')),
  creator_id UUID REFERENCES users(id),
  -- encrypted_secrets: tu peux conserver si tu l'utilises côté UI (sinon NULL)
  encrypted_secrets JSONB,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Participants aux conversations
CREATE TABLE IF NOT EXISTS conversation_users (
  conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  last_read_at TIMESTAMP WITH TIME ZONE,
  PRIMARY KEY (conversation_id, user_id)
);

-- Messages v2 (E2EE)
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id UUID REFERENCES users(id),
  sender_device_id TEXT NOT NULL,
  v SMALLINT NOT NULL DEFAULT 2,
  alg JSONB NOT NULL DEFAULT '{"kem":"X25519","kdf":"HKDF-SHA256","aead":"AES-256-GCM","sig":"Ed25519"}',
  message_id UUID NOT NULL,                      -- anti-replay (unique)
  sent_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  sender_eph_pub BYTEA NOT NULL,                -- 32B (X25519)
  iv BYTEA NOT NULL,                            -- 12B
  ciphertext BYTEA NOT NULL,                    -- blob chiffré
  wrapped_keys JSONB NOT NULL,                  -- [{userId,deviceId,wrap,nonce}]
  sig BYTEA NOT NULL,                           -- 64B (Ed25519)
  salt BYTEA NOT NULL,                          -- 32B HKDF salt (Base64)
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS uidx_messages_message_id
ON messages(message_id);

-- Refresh tokens
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT UNIQUE NOT NULL,
  expires_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Notifications
CREATE TABLE IF NOT EXISTS notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  payload JSONB NOT NULL,
  is_read BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_refresh_tokens_token_hash ON refresh_tokens(token_hash);
