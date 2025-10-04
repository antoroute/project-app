// backend/messaging/src/routes/keys.devices.ts
// Répertoire des clés par appareil pour un groupe + ajout/révocation d'appareils.

import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';

const DeviceKey = Type.Object({
  deviceId: Type.String({ minLength: 1, maxLength: 128 }),
  pk_sig: Type.String({ contentEncoding: 'base64' }), // 32B
  pk_kem: Type.String({ contentEncoding: 'base64' }), // 32B
  key_version: Type.Integer({ minimum: 1 }),
  attestation: Type.Optional(Type.String({ contentEncoding: 'base64' })) // TODO: vérifier signature par un device actif
});

export default async function routes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);

  app.get('/api/keys/group/:groupId', {
    schema: {
      params: Type.Object({ groupId: Type.String({ format: 'uuid' }) }),
      response: { 200: Type.Array(Type.Object({
        userId: Type.String({ format: 'uuid' }),
        deviceId: Type.String(),
        pk_sig: Type.String(),
        pk_kem: Type.String(),
        key_version: Type.Integer(),
        status: Type.String()
      })) }
    }
  }, async (req, reply) => {
    const { groupId } = req.params as any;
    const rows = await app.db.any(
      `SELECT user_id as "userId", device_id as "deviceId",
              encode(pk_sig,'base64') as "pk_sig",
              encode(pk_kem,'base64') as "pk_kem",
              key_version as "key_version",
              status
         FROM group_device_keys
         WHERE group_id = $1 AND status = 'active' 
           AND pk_sig IS NOT NULL 
           AND pk_kem IS NOT NULL
           AND length(pk_sig) = 32 
           AND length(pk_kem) = 32`,
      [groupId]
    );
    return rows;
  });

  app.post('/api/keys/group/:groupId/devices', {
    schema: {
      params: Type.Object({ groupId: Type.String({ format: 'uuid' }) }),
      body: DeviceKey,
      response: { 201: Type.Object({ ok: Type.Boolean() }) }
    }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { groupId } = req.params as any;
    const { deviceId, pk_sig, pk_kem, key_version } = req.body as any;

    await app.db.none(
      `INSERT INTO group_device_keys(group_id, user_id, device_id, pk_sig, pk_kem, key_version, status)
       VALUES($1,$2,$3, decode($4,'base64'), decode($5,'base64'), $6, 'active')
       ON CONFLICT (group_id, user_id, device_id)
       DO UPDATE SET pk_sig=EXCLUDED.pk_sig, pk_kem=EXCLUDED.pk_kem, key_version=EXCLUDED.key_version, status='active'`,
      [groupId, userId, deviceId, pk_sig, pk_kem, key_version]
    );
    reply.code(201);
    return { ok: true };
  });

  app.delete('/api/keys/group/:groupId/devices/:deviceId', {
    schema: {
      params: Type.Object({
        groupId: Type.String({ format: 'uuid' }),
        deviceId: Type.String()
      }),
      response: { 200: Type.Object({ ok: Type.Boolean() }) }
    }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { groupId, deviceId } = req.params as any;

    await app.db.none(
      `UPDATE group_device_keys SET status='revoked'
        WHERE group_id=$1 AND user_id=$2 AND device_id=$3`,
      [groupId, userId, deviceId]
    );
    return { ok: true };
  });
}
