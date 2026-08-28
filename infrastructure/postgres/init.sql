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

-- Autorisation courte délivrée après réauthentification pour le tout premier appareil.
CREATE TABLE IF NOT EXISTS device_bootstrap_grants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash BYTEA UNIQUE NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (octet_length(token_hash) = 32),
  CHECK (expires_at > created_at)
);

-- Identité de confiance au niveau du compte, distincte des clés E2EE par cercle.
CREATE TABLE IF NOT EXISTS account_devices (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id UUID NOT NULL,
  identity_public_key BYTEA NOT NULL,
  identity_key_version INT NOT NULL DEFAULT 1 CHECK (identity_key_version >= 1),
  platform TEXT NOT NULL CHECK (platform IN ('android','ios','windows','macos','unknown')),
  device_name TEXT NOT NULL CHECK (char_length(device_name) BETWEEN 1 AND 64),
  status TEXT NOT NULL CHECK (status IN ('pending','active','revoked')),
  proof_verified_at TIMESTAMPTZ NOT NULL,
  activated_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, device_id),
  UNIQUE (user_id, identity_public_key),
  CHECK (octet_length(identity_public_key) = 32),
  CHECK (status <> 'active' OR activated_at IS NOT NULL),
  CHECK (status <> 'pending' OR activated_at IS NULL),
  CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);

-- Challenges de preuve Ed25519. La transcription exacte est fournie au client.
CREATE TABLE IF NOT EXISTS device_registration_challenges (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id UUID NOT NULL,
  identity_public_key BYTEA NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('android','ios','windows','macos','unknown')),
  device_name TEXT NOT NULL CHECK (char_length(device_name) BETWEEN 1 AND 64),
  challenge_nonce BYTEA NOT NULL,
  transcript BYTEA NOT NULL,
  bootstrap_grant_id UUID REFERENCES device_bootstrap_grants(id) ON DELETE SET NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  result TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (octet_length(identity_public_key) = 32),
  CHECK (octet_length(challenge_nonce) = 32),
  CHECK (octet_length(transcript) = 163),
  CHECK (expires_at > created_at),
  CHECK (
    (consumed_at IS NULL AND result IS NULL)
    OR (consumed_at IS NOT NULL AND result IS NOT NULL)
  )
);

-- Décisions signées par un appareil actif pour un appareil encore en attente.
CREATE TABLE IF NOT EXISTS device_approval_challenges (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  approver_device_id UUID NOT NULL,
  approver_identity_key_version INT NOT NULL CHECK (approver_identity_key_version >= 1),
  approver_identity_public_key BYTEA NOT NULL,
  target_device_id UUID NOT NULL,
  target_identity_key_version INT NOT NULL CHECK (target_identity_key_version >= 1),
  target_identity_public_key BYTEA NOT NULL,
  decision TEXT NOT NULL CHECK (decision IN ('approve','reject','revoke')),
  challenge_nonce BYTEA NOT NULL,
  transcript BYTEA NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  result TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (user_id, approver_device_id)
    REFERENCES account_devices(user_id, device_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id, target_device_id)
    REFERENCES account_devices(user_id, device_id) ON DELETE CASCADE,
  CHECK (approver_device_id <> target_device_id),
  CHECK (octet_length(approver_identity_public_key) = 32),
  CHECK (octet_length(target_identity_public_key) = 32),
  CHECK (octet_length(challenge_nonce) = 32),
  CHECK (octet_length(transcript) = 216),
  CHECK (expires_at > created_at),
  CHECK (
    (consumed_at IS NULL AND result IS NULL)
    OR (consumed_at IS NOT NULL AND result IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_account_devices_user_status
  ON account_devices(user_id, status);

CREATE INDEX IF NOT EXISTS idx_device_challenges_outstanding
  ON device_registration_challenges(user_id, device_id, expires_at)
  WHERE consumed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_device_bootstrap_grants_user_expiry
  ON device_bootstrap_grants(user_id, expires_at);

CREATE INDEX IF NOT EXISTS idx_device_approvals_outstanding_target
  ON device_approval_challenges(user_id, target_device_id, expires_at)
  WHERE consumed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_device_approvals_approver_created
  ON device_approval_challenges(user_id, approver_device_id, created_at);

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
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('admin','member')),
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

CREATE UNIQUE INDEX IF NOT EXISTS uidx_join_requests_pending_group_user
  ON join_requests(group_id, user_id)
  WHERE status = 'pending';

-- Votes sur les demandes de jointure (un membre peut voter une seule fois par demande)
CREATE TABLE IF NOT EXISTS join_request_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  join_request_id UUID NOT NULL REFERENCES join_requests(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  vote BOOLEAN NOT NULL, -- true = oui, false = non
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(join_request_id, user_id)
);

-- Index pour améliorer les performances des requêtes de comptage
CREATE INDEX IF NOT EXISTS idx_join_request_votes_request_id ON join_request_votes(join_request_id);
CREATE INDEX IF NOT EXISTS idx_join_request_votes_user_id ON join_request_votes(user_id);

-- Clés publiques par GROUPE, par UTILISATEUR, par APPAREIL
CREATE TABLE IF NOT EXISTS group_device_keys (
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  pk_sig   BYTEA NOT NULL,        -- 32B
  pk_kem   BYTEA NOT NULL,        -- 32B
  key_version INT NOT NULL DEFAULT 1,
  identity_key_version INT,
  binding_signature BYTEA,
  status TEXT NOT NULL DEFAULT 'legacy'
    CHECK (status IN ('legacy', 'active', 'revoked')),
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,
  PRIMARY KEY (group_id, user_id, device_id),
  CHECK (identity_key_version IS NULL OR identity_key_version >= 1),
  CHECK (binding_signature IS NULL OR octet_length(binding_signature) = 64),
  CHECK (
    status <> 'active'
    OR (
      identity_key_version IS NOT NULL
      AND binding_signature IS NOT NULL
      AND octet_length(pk_sig) = 32
      AND octet_length(pk_kem) = 32
    )
  ),
  CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);

-- Versions historiques immuables nécessaires à la vérification des anciens messages.
CREATE TABLE IF NOT EXISTS group_device_key_history (
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  key_version INT NOT NULL CHECK (key_version >= 1),
  identity_key_version INT NOT NULL CHECK (identity_key_version >= 1),
  pk_sig BYTEA NOT NULL CHECK (octet_length(pk_sig) = 32),
  pk_kem BYTEA NOT NULL CHECK (octet_length(pk_kem) = 32),
  binding_signature BYTEA NOT NULL CHECK (octet_length(binding_signature) = 64),
  status TEXT NOT NULL CHECK (status IN ('superseded', 'revoked')),
  activated_at TIMESTAMPTZ NOT NULL,
  retired_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (group_id, user_id, device_id, key_version)
);

CREATE INDEX IF NOT EXISTS idx_group_device_key_history_lookup
  ON group_device_key_history(group_id, user_id, device_id, key_version);

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
