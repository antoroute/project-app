import {
  generateKeyPairSync,
  randomBytes,
  randomUUID,
  sign,
} from 'node:crypto';

const baseUrl = process.env.TC_DEVICE_TRUST_SMOKE_BASE_URL ??
  'http://gateway:8080';
const clientVersion = '2.0.0';

function requiredEnvironmentValue(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the device-trust smoke test`);
  return value;
}

const appSecret = requiredEnvironmentValue('APP_SECRET');

type JsonObject = Record<string, unknown>;

interface Identity {
  deviceId: string;
  publicKey: Buffer;
  privateKey: ReturnType<typeof generateKeyPairSync>['privateKey'];
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

async function request(
  path: string,
  method: 'GET' | 'POST',
  expectedStatus: number,
  body?: JsonObject,
  accessToken?: string,
): Promise<unknown> {
  const headers: Record<string, string> = {
    'x-app-secret': appSecret,
    'x-client-version': clientVersion,
  };
  if (body) headers['content-type'] = 'application/json';
  if (accessToken) headers.authorization = `Bearer ${accessToken}`;

  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const responseBody = await response.json().catch(() => null);
  if (response.status !== expectedStatus) {
    const error = responseBody && typeof responseBody === 'object'
      ? (responseBody as JsonObject).error
      : undefined;
    const safeError = typeof error === 'string' ? ` (${error})` : '';
    throw new Error(
      `${method} ${path}: expected ${expectedStatus}, got ${response.status}${safeError}`,
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

async function createAccount(label: string): Promise<{
  accessToken: string;
  password: string;
}> {
  const marker = randomUUID();
  const email = `tc106-${label}-${marker}@example.invalid`;
  const password = `Smoke-${randomBytes(18).toString('base64url')}`;
  await request('/auth/register', 'POST', 201, {
    email,
    username: `${label}_${marker.replaceAll('-', '').slice(0, 16)}`,
    password,
  });
  const login = objectValue(
    await request('/auth/login', 'POST', 200, { email, password }),
    'login',
  );
  return {
    accessToken: stringValue(login, 'access', 'login'),
    password,
  };
}

async function challenge(
  accessToken: string,
  identity: Identity,
  bootstrapGrant?: string,
): Promise<JsonObject> {
  return objectValue(
    await request(
      '/api/devices/registrations/challenge',
      'POST',
      201,
      {
        deviceId: identity.deviceId,
        identityPublicKey: identity.publicKey.toString('base64'),
        platform: 'unknown',
        deviceName: 'TC-106 staging smoke',
        ...(bootstrapGrant ? { bootstrapGrant } : {}),
      },
      accessToken,
    ),
    'device challenge',
  );
}

async function prove(
  accessToken: string,
  identity: Identity,
  deviceChallenge: JsonObject,
  expectedStatus: number,
): Promise<unknown> {
  const challengeId = stringValue(
    deviceChallenge,
    'challengeId',
    'device challenge',
  );
  const transcript = Buffer.from(
    stringValue(deviceChallenge, 'transcript', 'device challenge'),
    'base64',
  );
  if (transcript.length !== 163) {
    throw new Error('device challenge: unexpected transcript length');
  }
  const signature = sign(null, transcript, identity.privateKey).toString(
    'base64',
  );
  return request(
    `/api/devices/registrations/${challengeId}/proof`,
    'POST',
    expectedStatus,
    { signature },
    accessToken,
  );
}

async function decideDevice(
  accessToken: string,
  approver: Identity,
  target: Identity,
  decision: 'approve' | 'reject',
): Promise<{ challengeId: string; result: JsonObject }> {
  const approvalChallenge = objectValue(
    await request(
      `/api/devices/${target.deviceId}/approvals/challenge`,
      'POST',
      201,
      { approverDeviceId: approver.deviceId, decision },
      accessToken,
    ),
    'device approval challenge',
  );
  const challengeId = stringValue(
    approvalChallenge,
    'challengeId',
    'device approval challenge',
  );
  if (
    approvalChallenge.approverDeviceId !== approver.deviceId ||
    approvalChallenge.targetDeviceId !== target.deviceId ||
    approvalChallenge.decision !== decision
  ) {
    throw new Error('device approval challenge: unexpected binding');
  }
  const transcript = Buffer.from(
    stringValue(
      approvalChallenge,
      'transcript',
      'device approval challenge',
    ),
    'base64',
  );
  if (transcript.length !== 216) {
    throw new Error('device approval challenge: unexpected transcript length');
  }
  const signature = sign(null, transcript, approver.privateKey).toString(
    'base64',
  );
  const result = objectValue(
    await request(
      `/api/devices/approvals/${challengeId}/decision`,
      'POST',
      200,
      { signature },
      accessToken,
    ),
    'device approval result',
  );
  const expectedStatus = decision === 'approve' ? 'active' : 'revoked';
  if (
    result.approverDeviceId !== approver.deviceId ||
    result.targetDeviceId !== target.deviceId ||
    result.decision !== decision ||
    result.status !== expectedStatus
  ) {
    throw new Error('device approval result: unexpected transition');
  }
  return { challengeId, result };
}

const owner = await createAccount('owner');
const firstIdentity = createIdentity();
const grantResponse = objectValue(
  await request(
    '/auth/device-bootstrap-grant',
    'POST',
    201,
    { password: owner.password },
    owner.accessToken,
  ),
  'bootstrap grant',
);
const bootstrapGrant = stringValue(grantResponse, 'grant', 'bootstrap grant');
const firstChallenge = await challenge(
  owner.accessToken,
  firstIdentity,
  bootstrapGrant,
);
const firstProof = objectValue(
  await prove(owner.accessToken, firstIdentity, firstChallenge, 201),
  'first device proof',
);
if (firstProof.status !== 'active' || firstProof.bootstrap !== true) {
  throw new Error('first device proof: expected an active bootstrap');
}

await prove(owner.accessToken, firstIdentity, firstChallenge, 409);

const secondIdentity = createIdentity();
const secondChallenge = await challenge(owner.accessToken, secondIdentity);
const secondProof = objectValue(
  await prove(owner.accessToken, secondIdentity, secondChallenge, 201),
  'second device proof',
);
if (secondProof.status !== 'pending' || secondProof.bootstrap !== false) {
  throw new Error('second device proof: expected a pending device');
}

const devices = await request('/api/devices', 'GET', 200, undefined, owner.accessToken);
if (!Array.isArray(devices) || devices.length !== 2) {
  throw new Error('device registry: expected exactly two devices');
}
const statuses = devices
  .map((device) => objectValue(device, 'device registry row').status)
  .sort();
if (statuses[0] !== 'active' || statuses[1] !== 'pending') {
  throw new Error('device registry: expected active and pending statuses');
}

const approval = await decideDevice(
  owner.accessToken,
  firstIdentity,
  secondIdentity,
  'approve',
);
await request(
  `/api/devices/approvals/${approval.challengeId}/decision`,
  'POST',
  409,
  { signature: Buffer.alloc(64).toString('base64') },
  owner.accessToken,
);

const thirdIdentity = createIdentity();
const thirdChallenge = await challenge(owner.accessToken, thirdIdentity);
const thirdProof = objectValue(
  await prove(owner.accessToken, thirdIdentity, thirdChallenge, 201),
  'third device proof',
);
if (thirdProof.status !== 'pending' || thirdProof.bootstrap !== false) {
  throw new Error('third device proof: expected a pending device');
}
await decideDevice(
  owner.accessToken,
  firstIdentity,
  thirdIdentity,
  'reject',
);

const decidedDevices = await request(
  '/api/devices',
  'GET',
  200,
  undefined,
  owner.accessToken,
);
if (!Array.isArray(decidedDevices) || decidedDevices.length !== 3) {
  throw new Error('device registry: expected exactly three decided devices');
}
const decidedStatuses = decidedDevices
  .map((device) => objectValue(device, 'device registry row').status)
  .sort();
if (
  decidedStatuses[0] !== 'active' ||
  decidedStatuses[1] !== 'active' ||
  decidedStatuses[2] !== 'revoked'
) {
  throw new Error('device registry: expected active, active and revoked');
}

const accessOnlyAccount = await createAccount('access_only');
const attackerIdentity = createIdentity();
const attackerChallenge = await challenge(
  accessOnlyAccount.accessToken,
  attackerIdentity,
);
const deniedProof = objectValue(
  await prove(
    accessOnlyAccount.accessToken,
    attackerIdentity,
    attackerChallenge,
    403,
  ),
  'access-token-only bootstrap',
);
if (deniedProof.error !== 'bootstrap_authorization_required') {
  throw new Error('access-token-only bootstrap: unexpected denial reason');
}

console.log(
  'Device trust smoke passed: password-bound bootstrap, Ed25519 proof, signed approval/rejection, replay denial and subject-scoped registry.',
);
