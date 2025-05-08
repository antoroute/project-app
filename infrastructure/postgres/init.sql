-- Extensions nécessaires
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Table des utilisateurs
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  password TEXT NOT NULL,
  username TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  public_key TEXT
);

-- Table des groupes
CREATE TABLE IF NOT EXISTS groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id UUID REFERENCES users(id),
  name TEXT UNIQUE NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Table de liaison utilisateur↔groupe
CREATE TABLE IF NOT EXISTS user_groups (
  user_id UUID REFERENCES users(id)    ON DELETE CASCADE,
  group_id UUID REFERENCES groups(id)  ON DELETE CASCADE,
  public_key_group TEXT NOT NULL,
  PRIMARY KEY (user_id, group_id)
);

-- Requêtes d’adhésion à un groupe
CREATE TABLE IF NOT EXISTS join_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id  UUID NOT NULL REFERENCES users(id)  ON DELETE CASCADE,
  public_key_group TEXT NOT NULL,
  status TEXT NOT NULL
    CHECK (status IN ('pending','accepted','rejected'))
    DEFAULT 'pending',
  handled_by UUID REFERENCES users(id),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Votes sur ces requêtes
CREATE TABLE IF NOT EXISTS join_request_votes (
  request_id UUID NOT NULL REFERENCES join_requests(id) ON DELETE CASCADE,
  voter_id   UUID NOT NULL REFERENCES users(id)         ON DELETE CASCADE,
  vote BOOLEAN NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (request_id, voter_id)
);

-- Conversations (privées ou subset)
CREATE TABLE IF NOT EXISTS conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id),
  type TEXT NOT NULL CHECK (type IN ('private','subset')),
  creator_id UUID REFERENCES users(id),
  encrypted_secrets JSONB,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Participants aux conversations
CREATE TABLE IF NOT EXISTS conversation_users (
  conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE,
  user_id         UUID REFERENCES users(id)         ON DELETE CASCADE,
  PRIMARY KEY (conversation_id, user_id)
);

-- Messages E2EE
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id UUID REFERENCES users(id),
  encrypted_message TEXT NOT NULL,
  encrypted_keys    JSONB NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  signature_valid BOOLEAN DEFAULT TRUE
);

-- Table des refresh tokens pour la rotation
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token TEXT UNIQUE NOT NULL,
  expires_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token ON refresh_tokens(token);