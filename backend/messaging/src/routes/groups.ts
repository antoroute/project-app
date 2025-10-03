// backend/messaging/src/routes/groups.ts
// Groupes : créer, lister, join requests (v2 inclut deviceId + clés publiques), accepter/rejeter.

import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';

export default async function routes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);

  // POST /api/groups  { name, groupSigningPubKey, groupKEMPubKey }
  app.post('/api/groups', {
    schema: { 
      body: Type.Object({ 
        name: Type.String({ minLength: 3, maxLength: 64 }),
        groupSigningPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' })),
        groupKEMPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' }))
      }) 
    }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { name, groupSigningPubKey, groupKEMPubKey } = req.body as any;

    const g = await app.db.one(
      `INSERT INTO groups(name, creator_id) VALUES($1,$2) RETURNING id`,
      [name, userId]
    );
    
    // Ajouter les clés du groupe si fournies
    if (groupSigningPubKey) {
      await app.db.none(
        `INSERT INTO group_keys(group_id, pk_sig, key_version) VALUES($1,decode($2,'base64'),1)`,
        [g.id, groupSigningPubKey]
      );
    }
    
    await app.db.none(
      `INSERT INTO user_groups(user_id, group_id) VALUES($1,$2)`,
      [userId, g.id]
    );

    reply.code(201); // Explicitement retourner le code 201 Created
    return { groupId: g.id, name };
  });

  // GET /api/groups  : groupes dont je suis membre
  app.get('/api/groups', async (req, reply) => {
    const userId = (req.user as any).sub;
    const rows = await app.db.any(
      `SELECT g.id, g.name, g.creator_id, g.created_at as "createdAt"
         FROM groups g
         JOIN user_groups ug ON ug.group_id=g.id
        WHERE ug.user_id=$1
        ORDER BY g.created_at DESC`,
      [userId]
    );
    return rows;
  });

  // POST /api/groups/:id/join  { deviceId, pk_sig, pk_kem, groupSigningPubKey, groupKEMPubKey }
  // Crée une join_request (v2) incluant les clés de l'appareil initial et du groupe
  app.post('/api/groups/:id/join', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) }),
      body: Type.Object({
        deviceId: Type.String({ minLength: 1, maxLength: 128 }),
        pk_sig: Type.String({ contentEncoding: 'base64' }),
        pk_kem: Type.String({ contentEncoding: 'base64' }),
        groupSigningPubKey: Type.String({ contentEncoding: 'base64' }),
        groupKEMPubKey: Type.String({ contentEncoding: 'base64' })
      })
    }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { id: groupId } = req.params as any;
    const { deviceId, pk_sig, pk_kem, groupSigningPubKey, groupKEMPubKey } = req.body as any;

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

  // POST /api/groups/:id/join-requests { groupSigningPubKey, groupKEMPubKey }
  // Crée une demande de jointure avec les clés du groupe  
  app.post('/api/groups/:id/join-requests', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) }),
      body: Type.Object({
        groupSigningPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' })),
        groupKEMPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' }))
      })
    }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { id: groupId } = req.params as any;
    const { groupSigningPubKey, groupKEMPubKey } = req.body as any;

    // refuse si déjà membre
    const m = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [userId, groupId]);
    if (m.length) return reply.code(409).send({ error: 'already_member' });

    // Pour l'instant, on crée une demande simple sans clés de device
    const jr = await app.db.one(
      `INSERT INTO join_requests(group_id, user_id, device_id, pk_sig, pk_kem)
       VALUES($1,$2,$3,'','')
       RETURNING id`,
      [groupId, userId, userId + '_tmp_' + Date.now()]
    );
    return { requestId: jr.id, status: 'pending' };
  });

  // GET /api/groups/:id/join-requests
  // Récupère les demandes de jointure pour un groupe (pour les admins/membres)
  app.get('/api/groups/:id/join-requests', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) })
    }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { id: groupId } = req.params as any;

    // Vérifie que l'utilisateur est membre du groupe
    const m = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [userId, groupId]);
    if (!m.length) return reply.code(403).send({ error: 'forbidden' });

    const rows = await app.db.any(
      `SELECT jr.id, jr.user_id, jr.device_id, jr.status, jr.created_at,
              u.email, u.username
         FROM join_requests jr
         JOIN users u ON u.id = jr.user_id
        WHERE jr.group_id = $1 AND jr.status = 'pending'
        ORDER BY jr.created_at DESC`,
      [groupId]
    );
    
    return rows.map((row: { id: any; user_id: any; device_id: any; status: any; created_at: { toISOString: () => any; }; email: any; username: any; }) => ({
      id: row.id,
      userId: row.user_id,
      deviceId: row.device_id,
      status: row.status,
      createdAt: row.created_at.toISOString(),
      email: row.email,
      username: row.username
    }));
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
