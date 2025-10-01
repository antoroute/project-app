// backend/messaging/src/routes/groups.ts
// Groupes : créer, lister, join requests (v2 inclut deviceId + clés publiques), accepter/rejeter.

import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';

export default async function routes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);

  // POST /api/groups  { name }
  app.post('/api/groups', {
    schema: { body: Type.Object({ name: Type.String({ minLength: 3, maxLength: 64 }) }) }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { name } = req.body as any;

    const g = await app.db.one(
      `INSERT INTO groups(name, creator_id) VALUES($1,$2) RETURNING id`,
      [name, userId]
    );
    await app.db.none(
      `INSERT INTO user_groups(user_id, group_id) VALUES($1,$2)`,
      [userId, g.id]
    );

    return { id: g.id, name };
  });

  // GET /api/groups  : groupes dont je suis membre
  app.get('/api/groups', async (req, reply) => {
    const userId = (req.user as any).sub;
    const rows = await app.db.any(
      `SELECT g.id, g.name, g.created_at as "createdAt"
         FROM groups g
         JOIN user_groups ug ON ug.group_id=g.id
        WHERE ug.user_id=$1
        ORDER BY g.created_at DESC`,
      [userId]
    );
    return rows;
  });

  // POST /api/groups/:id/join  { deviceId, pk_sig, pk_kem }
  // Crée une join_request (v2) incluant les clés de l'appareil initial
  app.post('/api/groups/:id/join', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) }),
      body: Type.Object({
        deviceId: Type.String({ minLength: 1, maxLength: 128 }),
        pk_sig: Type.String({ contentEncoding: 'base64' }),
        pk_kem: Type.String({ contentEncoding: 'base64' })
      })
    }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { id: groupId } = req.params as any;
    const { deviceId, pk_sig, pk_kem } = req.body as any;

    // refuse si déjà membre
    const m = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [userId, groupId]);
    if (m.length) return reply.code(409).send({ error: 'already_member' });

    const jr = await app.db.one(
      `INSERT INTO join_requests(group_id, user_id, device_id, pk_sig, pk_kem)
       VALUES($1,$2,$3, decode($4,'base64'), decode($5,'base64'))
       RETURNING id`,
      [groupId, userId, deviceId, pk_sig, pk_kem]
    );
    return { id: jr.id, status: 'pending' };
  });

  // POST /api/groups/:id/requests/:rid/accept
  app.post('/api/groups/:id/requests/:rid/accept', {
    schema: {
      params: Type.Object({
        id: Type.String({ format: 'uuid' }),
        rid: Type.String({ format: 'uuid' })
      })
    }
  }, async (req, reply) => {
    const approverId = (req.user as any).sub;
    const { id: groupId, rid } = req.params as any;

    // Vérifie que l'approver est membre du groupe (politique simple)
    const a = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [approverId, groupId]);
    if (!a.length) return reply.code(403).send({ error: 'forbidden' });

    const jr = await app.db.one(`SELECT * FROM join_requests WHERE id=$1 AND group_id=$2 AND status='pending'`, [rid, groupId]);

    // Ajoute le user
    await app.db.none(`INSERT INTO user_groups(user_id, group_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, [jr.user_id, groupId]);

    // Publie la clé device initiale comme active
    await app.db.none(
      `INSERT INTO group_device_keys(group_id, user_id, device_id, pk_sig, pk_kem, key_version, status)
       VALUES($1,$2,$3,$4,$5,1,'active')
       ON CONFLICT (group_id,user_id,device_id) DO NOTHING`,
      [groupId, jr.user_id, jr.device_id, jr.pk_sig, jr.pk_kem]
    );

    // Marque la requête comme acceptée
    await app.db.none(`UPDATE join_requests SET status='accepted', handled_by=$1 WHERE id=$2`, [approverId, rid]);

    return { ok: true };
  });

  // POST /api/groups/:id/requests/:rid/reject
  app.post('/api/groups/:id/requests/:rid/reject', {
    schema: {
      params: Type.Object({
        id: Type.String({ format: 'uuid' }),
        rid: Type.String({ format: 'uuid' })
      })
    }
  }, async (req, reply) => {
    const approverId = (req.user as any).sub;
    const { id: groupId, rid } = req.params as any;

    const a = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [approverId, groupId]);
    if (!a.length) return reply.code(403).send({ error: 'forbidden' });

    await app.db.none(`UPDATE join_requests SET status='rejected', handled_by=$1 WHERE id=$2`, [approverId, rid]);
    return { ok: true };
  });
}
