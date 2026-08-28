import {
  generateKeyPairSync,
  randomBytes,
  randomUUID,
  sign,
} from 'node:crypto';

import { createDeviceAccessTranscript } from '../security/deviceAccess.js';
import { createGroupDeviceKeyTranscript } from '../security/groupDeviceKeyBinding.js';

const baseUrl = process.env.TC_DEVICE_TRUST_SMOKE_BASE_URL ??
  'http://gateway:8080';
const clientVersion = '2.0.0';

function requiredEnvironmentValue(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the staging smoke test`);
  return value;
}

const appSecret = requiredEnvironmentValue('APP_SECRET');
type JsonObject = Record<string, unknown>;
type Method = 'GET' | 'POST' | 'PATCH' | 'DELETE';

interface Identity {
  deviceId: string;
  publicKey: Buffer;
  privateKey: ReturnType<typeof generateKeyPairSync>['privateKey'];
}

interface Account {
  userId: string;
  accessToken: string;
  refreshToken: string;
  password: string;
}

interface CircleKeyMaterial {
  pkSig: Buffer;
  pkKem: Buffer;
}

function objectValue(value: unknown, context: string): JsonObject {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${context}: expected a JSON object`);
  }
  return value as JsonObject;
}

function stringValue(
  object: JsonObject,
  property: string,
  context: string,
): string {
  const value = object[property];
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${context}: missing ${property}`);
  }
  return value;
}

function tokenClaims(accessToken: string): { sub: string; jti: string } {
  const segments = accessToken.split('.');
  if (segments.length !== 3) throw new Error('access token: malformed JWT');
  const payload = objectValue(
    JSON.parse(Buffer.from(segments[1], 'base64url').toString('utf8')),
    'access token payload',
  );
  return {
    sub: stringValue(payload, 'sub', 'access token payload'),
    jti: stringValue(payload, 'jti', 'access token payload'),
  };
}

function deviceAccessHeaders(
  accessToken: string,
  identity: Identity,
): Record<string, string> {
  const claims = tokenClaims(accessToken);
  const transcript = createDeviceAccessTranscript({
    accountId: claims.sub,
    deviceId: identity.deviceId,
    identityKeyVersion: 1,
    accessTokenId: claims.jti,
  });
  return {
    'x-circlehaven-device-id': identity.deviceId,
    'x-circlehaven-device-key-version': '1',
    'x-circlehaven-device-proof': sign(
      null,
      transcript,
      identity.privateKey,
    ).toString('base64'),
  };
}

async function request(
  path: string,
  method: Method,
  expectedStatus: number | readonly number[],
  options: {
    body?: JsonObject;
    token?: string;
    identity?: Identity;
  } = {},
): Promise<unknown> {
  const headers: Record<string, string> = {
    'x-app-secret': appSecret,
    'x-client-version': clientVersion,
  };
  if (options.body) headers['content-type'] = 'application/json';
  if (options.token) headers.authorization = `Bearer ${options.token}`;
  if (options.token && options.identity) {
    Object.assign(headers, deviceAccessHeaders(options.token, options.identity));
  }

  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const responseBody = await response.json().catch(() => null);
  const accepted = Array.isArray(expectedStatus)
    ? expectedStatus.includes(response.status)
    : response.status === expectedStatus;
  if (!accepted) {
    const error = responseBody && typeof responseBody === 'object'
      ? (responseBody as JsonObject).error
      : undefined;
    const safeError = typeof error === 'string' ? ` (${error})` : '';
    throw new Error(
      `${method} ${path}: expected ${String(expectedStatus)}, got ${response.status}${safeError}`,
    );
  }
  return responseBody;
}

function createIdentity(): Identity {
  const keyPair = generateKeyPairSync('ed25519');
  const publicDer = keyPair.publicKey.export({ format: 'der', type: 'spki' });
  return {
    deviceId: randomUUID(),
    publicKey: Buffer.from(publicDer).subarray(-32),
    privateKey: keyPair.privateKey,
  };
}

function createCircleKeys(): CircleKeyMaterial {
  return { pkSig: randomBytes(32), pkKem: randomBytes(32) };
}

async function createAccount(label: string): Promise<Account> {
  const marker = randomUUID();
  const email = `tc106-${label}-${marker}@example.invalid`;
  const password = `Smoke-${randomBytes(18).toString('base64url')}`;
  const registration = objectValue(
    await request('/auth/register', 'POST', 201, {
      body: {
        email,
        username: `${label}_${marker.replaceAll('-', '').slice(0, 16)}`,
        password,
      },
    }),
    'registration',
  );
  const login = objectValue(
    await request('/auth/login', 'POST', 200, {
      body: { email, password },
    }),
    'login',
  );
  return {
    userId: stringValue(registration, 'id', 'registration'),
    accessToken: stringValue(login, 'access', 'login'),
    refreshToken: stringValue(login, 'refresh', 'login'),
    password,
  };
}

async function registrationChallenge(
  account: Account,
  identity: Identity,
  bootstrapGrant?: string,
): Promise<JsonObject> {
  return objectValue(
    await request('/api/devices/registrations/challenge', 'POST', 201, {
      token: account.accessToken,
      body: {
        deviceId: identity.deviceId,
        identityPublicKey: identity.publicKey.toString('base64'),
        platform: 'unknown',
        deviceName: 'TC-106 staging smoke',
        ...(bootstrapGrant ? { bootstrapGrant } : {}),
      },
    }),
    'device registration challenge',
  );
}

async function proveRegistration(
  account: Account,
  identity: Identity,
  challenge: JsonObject,
  expectedStatus: number,
): Promise<unknown> {
  const transcript = Buffer.from(
    stringValue(challenge, 'transcript', 'device registration challenge'),
    'base64',
  );
  if (transcript.length !== 163) {
    throw new Error('device registration challenge: bad transcript length');
  }
  return request(
    `/api/devices/registrations/${stringValue(challenge, 'challengeId', 'device registration challenge')}/proof`,
    'POST',
    expectedStatus,
    {
      token: account.accessToken,
      body: {
        signature: sign(null, transcript, identity.privateKey).toString(
          'base64',
        ),
      },
    },
  );
}

async function bootstrapFirstDevice(
  account: Account,
  identity: Identity,
): Promise<void> {
  const grant = objectValue(
    await request('/auth/device-bootstrap-grant', 'POST', 201, {
      token: account.accessToken,
      body: { password: account.password },
    }),
    'bootstrap grant',
  );
  const challenge = await registrationChallenge(
    account,
    identity,
    stringValue(grant, 'grant', 'bootstrap grant'),
  );
  const proof = objectValue(
    await proveRegistration(account, identity, challenge, 201),
    'first device proof',
  );
  if (proof.status !== 'active' || proof.bootstrap !== true) {
    throw new Error('first device proof: expected active bootstrap');
  }
  await proveRegistration(account, identity, challenge, 409);
}

async function registerFollowingDevice(
  account: Account,
  identity: Identity,
): Promise<void> {
  const challenge = await registrationChallenge(account, identity);
  const proof = objectValue(
    await proveRegistration(account, identity, challenge, 201),
    'following device proof',
  );
  if (proof.status !== 'pending' || proof.bootstrap !== false) {
    throw new Error('following device proof: expected pending');
  }
}

async function signedDecision(
  account: Account,
  approver: Identity,
  target: Identity,
  decision: 'approve' | 'reject' | 'revoke',
): Promise<{ path: string; signature: string }> {
  const challenge = objectValue(
    await request(
      `/api/devices/${target.deviceId}/approvals/challenge`,
      'POST',
      201,
      {
        token: account.accessToken,
        identity: approver,
        body: { approverDeviceId: approver.deviceId, decision },
      },
    ),
    'device decision challenge',
  );
  const transcript = Buffer.from(
    stringValue(challenge, 'transcript', 'device decision challenge'),
    'base64',
  );
  if (transcript.length !== 216 || challenge.decision !== decision) {
    throw new Error('device decision challenge: invalid binding');
  }
  return {
    path: `/api/devices/approvals/${stringValue(challenge, 'challengeId', 'device decision challenge')}/decision`,
    signature: sign(null, transcript, approver.privateKey).toString('base64'),
  };
}

async function decideDevice(
  account: Account,
  approver: Identity,
  target: Identity,
  decision: 'approve' | 'reject' | 'revoke',
): Promise<JsonObject> {
  const proof = await signedDecision(account, approver, target, decision);
  return objectValue(
    await request(proof.path, 'POST', 200, {
      token: account.accessToken,
      identity: approver,
      body: { signature: proof.signature },
    }),
    'device decision',
  );
}

function keyPublication(
  account: Account,
  identity: Identity,
  groupId: string,
  keyVersion: number,
  keys: CircleKeyMaterial,
): JsonObject {
  const transcript = createGroupDeviceKeyTranscript({
    accountId: account.userId,
    groupId,
    deviceId: identity.deviceId,
    identityKeyVersion: 1,
    keyVersion,
    signaturePublicKey: keys.pkSig,
    kemPublicKey: keys.pkKem,
  });
  return {
    deviceId: identity.deviceId,
    pk_sig: keys.pkSig.toString('base64'),
    pk_kem: keys.pkKem.toString('base64'),
    key_version: keyVersion,
    identityKeyVersion: 1,
    bindingSignature: sign(null, transcript, identity.privateKey).toString(
      'base64',
    ),
  };
}

function messageBody(input: {
  account: Account;
  identity: Identity;
  groupId: string;
  conversationId: string;
  senderKeyVersion: number;
  recipientIdentity: Identity;
  recipientKeyVersion: number;
}): JsonObject {
  return {
    v: 2,
    alg: {
      kem: 'X25519',
      kdf: 'HKDF-SHA256',
      aead: 'AES-256-GCM',
      sig: 'Ed25519',
    },
    groupId: input.groupId,
    convId: input.conversationId,
    messageId: randomUUID(),
    sentAt: Math.floor(Date.now() / 1000),
    sender: {
      userId: input.account.userId,
      deviceId: input.identity.deviceId,
      eph_pub: randomBytes(32).toString('base64'),
      key_version: input.senderKeyVersion,
    },
    recipients: [
      {
        userId: input.account.userId,
        deviceId: input.recipientIdentity.deviceId,
        key_version: input.recipientKeyVersion,
        wrap: randomBytes(48).toString('base64'),
        nonce: randomBytes(12).toString('base64'),
      },
    ],
    iv: randomBytes(12).toString('base64'),
    ciphertext: randomBytes(32).toString('base64'),
    sig: randomBytes(64).toString('base64'),
    salt: randomBytes(32).toString('base64'),
  };
}

const owner = await createAccount('owner');
const firstIdentity = createIdentity();
await bootstrapFirstDevice(owner, firstIdentity);

await request('/api/groups', 'GET', 403, { token: owner.accessToken });
await request('/api/groups', 'GET', 401, { token: owner.refreshToken });

const secondIdentity = createIdentity();
await registerFollowingDevice(owner, secondIdentity);
const pendingView = await request('/api/devices', 'GET', 200, {
  token: owner.accessToken,
  identity: secondIdentity,
});
if (!Array.isArray(pendingView) || pendingView.length !== 1) {
  throw new Error('pending device: registry view must contain itself only');
}
const initialRegistry = await request('/api/devices', 'GET', 200, {
  token: owner.accessToken,
  identity: firstIdentity,
});
if (!Array.isArray(initialRegistry) || initialRegistry.length !== 2) {
  throw new Error('active device: expected complete account registry');
}
await decideDevice(owner, firstIdentity, secondIdentity, 'approve');

const rejectedIdentity = createIdentity();
await registerFollowingDevice(owner, rejectedIdentity);
await decideDevice(owner, firstIdentity, rejectedIdentity, 'reject');

const group = objectValue(
  await request('/api/groups', 'POST', 201, {
    token: owner.accessToken,
    identity: firstIdentity,
    body: { name: `TC-106 lot D ${randomUUID()}` },
  }),
  'group creation',
);
const groupId = stringValue(group, 'groupId', 'group creation');
const conversation = objectValue(
  await request('/api/conversations', 'POST', 201, {
    token: owner.accessToken,
    identity: firstIdentity,
    body: { groupId, type: 'private', memberIds: [] },
  }),
  'conversation creation',
);
const conversationId = stringValue(conversation, 'id', 'conversation creation');

const firstV1 = createCircleKeys();
const firstV2 = createCircleKeys();
const secondV1 = createCircleKeys();
const firstV1Publication = keyPublication(
  owner,
  firstIdentity,
  groupId,
  1,
  firstV1,
);
await request(`/api/keys/group/${groupId}/devices`, 'POST', 201, {
  token: owner.accessToken,
  identity: firstIdentity,
  body: firstV1Publication,
});
const replay = objectValue(
  await request(`/api/keys/group/${groupId}/devices`, 'POST', 201, {
    token: owner.accessToken,
    identity: firstIdentity,
    body: firstV1Publication,
  }),
  'idempotent key replay',
);
if (replay.rotated !== false) throw new Error('key replay must be idempotent');

await request('/api/messages', 'POST', 201, {
  token: owner.accessToken,
  identity: firstIdentity,
  body: messageBody({
    account: owner,
    identity: firstIdentity,
    groupId,
    conversationId,
    senderKeyVersion: 1,
    recipientIdentity: firstIdentity,
    recipientKeyVersion: 1,
  }),
});

await request(`/api/keys/group/${groupId}/devices`, 'POST', 201, {
  token: owner.accessToken,
  identity: firstIdentity,
  body: keyPublication(owner, firstIdentity, groupId, 2, firstV2),
});
await request(`/api/keys/group/${groupId}/devices`, 'POST', 409, {
  token: owner.accessToken,
  identity: firstIdentity,
  body: keyPublication(owner, firstIdentity, groupId, 4, createCircleKeys()),
});

const directoryAfterRotation = await request(
  `/api/keys/group/${groupId}`,
  'GET',
  200,
  { token: owner.accessToken, identity: firstIdentity },
);
if (
  !Array.isArray(directoryAfterRotation) ||
  !directoryAfterRotation.some((entry) => {
    const row = objectValue(entry, 'directory entry');
    return row.key_version === 1 && row.status === 'superseded';
  }) ||
  !directoryAfterRotation.some((entry) => {
    const row = objectValue(entry, 'directory entry');
    return row.key_version === 2 && row.status === 'active';
  })
) {
  throw new Error('rotation: active and historical versions are not visible');
}

await request('/api/messages', 'POST', 403, {
  token: owner.accessToken,
  identity: firstIdentity,
  body: messageBody({
    account: owner,
    identity: firstIdentity,
    groupId,
    conversationId,
    senderKeyVersion: 1,
    recipientIdentity: firstIdentity,
    recipientKeyVersion: 2,
  }),
});
await request('/api/messages', 'POST', 201, {
  token: owner.accessToken,
  identity: firstIdentity,
  body: messageBody({
    account: owner,
    identity: firstIdentity,
    groupId,
    conversationId,
    senderKeyVersion: 2,
    recipientIdentity: firstIdentity,
    recipientKeyVersion: 2,
  }),
});

const secondPublication = keyPublication(
  owner,
  secondIdentity,
  groupId,
  1,
  secondV1,
);
await request(`/api/keys/group/${groupId}/devices`, 'POST', 201, {
  token: owner.accessToken,
  identity: secondIdentity,
  body: secondPublication,
});
const revokeProof = await signedDecision(
  owner,
  firstIdentity,
  secondIdentity,
  'revoke',
);
const [revocationResult] = await Promise.all([
  request(revokeProof.path, 'POST', 200, {
    token: owner.accessToken,
    identity: firstIdentity,
    body: { signature: revokeProof.signature },
  }),
  request(`/api/keys/group/${groupId}/devices`, 'POST', [201, 403], {
    token: owner.accessToken,
    identity: secondIdentity,
    body: secondPublication,
  }),
]);
if (objectValue(revocationResult, 'revocation result').status !== 'revoked') {
  throw new Error('revocation: target did not become revoked');
}

await request('/api/groups', 'GET', 403, {
  token: owner.accessToken,
  identity: secondIdentity,
});
await request('/api/messages', 'POST', 403, {
  token: owner.accessToken,
  identity: firstIdentity,
  body: messageBody({
    account: owner,
    identity: firstIdentity,
    groupId,
    conversationId,
    senderKeyVersion: 2,
    recipientIdentity: secondIdentity,
    recipientKeyVersion: 1,
  }),
});

const finalDirectory = await request(`/api/keys/group/${groupId}`, 'GET', 200, {
  token: owner.accessToken,
  identity: firstIdentity,
});
if (
  !Array.isArray(finalDirectory) ||
  !finalDirectory.some((entry) => {
    const row = objectValue(entry, 'final directory entry');
    return row.deviceId === secondIdentity.deviceId && row.status === 'revoked';
  })
) {
  throw new Error('revocation: directory did not expose revoked current key');
}

const historicalMessages = objectValue(
  await request(`/api/conversations/${conversationId}/messages`, 'GET', 200, {
    token: owner.accessToken,
    identity: firstIdentity,
  }),
  'historical messages',
);
if (
  !Array.isArray(historicalMessages.items) ||
  historicalMessages.items.length < 2
) {
  throw new Error('message history: expected messages across key rotation');
}

const accessOnly = await createAccount('access-only');
const attackerIdentity = createIdentity();
const attackerChallenge = await registrationChallenge(
  accessOnly,
  attackerIdentity,
);
const deniedBootstrap = objectValue(
  await proveRegistration(accessOnly, attackerIdentity, attackerChallenge, 403),
  'access-token-only bootstrap',
);
if (deniedBootstrap.error !== 'bootstrap_authorization_required') {
  throw new Error('access-token-only bootstrap: unexpected denial');
}

console.log(
  'TC-106 lot D smoke passed: device PoP, pending isolation, signed decisions, signed key publication, idempotence, rotation/history, stale-version denial, concurrent global revocation and immediate message/access denial.',
);
