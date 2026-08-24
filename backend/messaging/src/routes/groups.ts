// backend/messaging/src/routes/groups.ts
// Groupes : créer, lister, join requests (v2 inclut deviceId + clés publiques), accepter/rejeter.

import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';

import { authenticatedUserId } from '../security/jwt.js';

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
    const userId = authenticatedUserId(req);
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

    // CORRECTION: S'assurer que le créateur est dans la room AVANT d'émettre l'événement
    // Rejoindre le créateur à la room du groupe
    app.io.in(`user:${userId}`).socketsJoin(`group:${g.id}`);
    app.log.info({ groupId: g.id, userId }, 'Creator joined group room');

    // SÉCURITÉ: Émettre uniquement un ping minimal (pas de données sensibles)
    // Le créateur n'a pas besoin de notification car il vient de créer le groupe
    // Les autres utilisateurs recevront la notification quand ils rejoindront le groupe
    // Note: On n'émet rien ici car le créateur est déjà au courant
    app.log.info({ groupId: g.id, userId }, 'Group created (no notification needed for creator)');

    reply.code(201); // Explicitement retourner le code 201 Created
    return { groupId: g.id, name };
  });

  // GET /api/groups  : groupes dont je suis membre
  app.get('/api/groups', async (req, reply) => {
    const userId = authenticatedUserId(req);
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

  // GET /api/groups/:id : détails d'un groupe spécifique
  app.get('/api/groups/:id', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: groupId } = req.params as any;

    // Vérifie que l'utilisateur est membre du groupe
    const membership = await app.db.any(
      `SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`,
      [userId, groupId]
    );
    
    if (membership.length === 0) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    // Récupère les détails du groupe
    const groups = await app.db.any(
      `SELECT g.id, g.name, g.creator_id, g.created_at
        FROM groups g WHERE g.id=$1`,
      [groupId]
    );

    if (groups.length === 0) {
      return reply.code(404).send({ error: 'group_not_found' });
    }

    const group = groups[0];

    return {
      id: group.id,
      name: group.name,
      creatorId: group.creator_id,
      createdAt: group.created_at.toISOString()
    };
  });

  // GET /api/groups/:id/members : membres d'un groupe
  app.get('/api/groups/:id/members', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: groupId } = req.params as any;

    // Vérifie que l'utilisateur est membre du groupe
    const membership = await app.db.any(
      `SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`,
      [userId, groupId]
    );
    
    if (membership.length === 0) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    // Récupère les membres du groupe
    const members = await app.db.any(
      `SELECT u.id, u.email, u.username, u.created_at
        FROM users u
        JOIN user_groups ug ON ug.user_id = u.id
        WHERE ug.group_id = $1
        ORDER BY u.username`,
      [groupId]
    );

    return members.map((member: any) => ({
      userId: member.id,
      email: member.email,
      username: member.username,
      joinedAt: member.created_at.toISOString()
    }));
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
    const userId = authenticatedUserId(req);
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
  // Route legacy - SEUL LE CRÉATEUR PEUT ACCEPTER
  app.post('/api/groups/:id/requests/:rid/accept', {
    schema: {
      params: Type.Object({
        id: Type.String({ format: 'uuid' }),
        rid: Type.String({ format: 'uuid' })
      })
    }
  }, async (req, reply) => {
    const approverId = authenticatedUserId(req);
    const { id: groupId, rid } = req.params as any;

    // Vérifie que l'approver est membre du groupe
    const a = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [approverId, groupId]);
    if (!a.length) return reply.code(403).send({ error: 'forbidden' });

    // Vérifie que l'approver est le créateur du groupe
    const group = await app.db.oneOrNone(`SELECT creator_id FROM groups WHERE id=$1`, [groupId]);
    if (!group) return reply.code(404).send({ error: 'group_not_found' });
    if (group.creator_id !== approverId) {
      return reply.code(403).send({ error: 'only_creator_can_handle' });
    }

    const jr = await app.db.one(`SELECT * FROM join_requests WHERE id=$1 AND group_id=$2 AND status='pending'`, [rid, groupId]);

    // Ajoute le user
    await app.db.none(`INSERT INTO user_groups(user_id, group_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, [jr.user_id, groupId]);

    // 🚀 NOUVEAU: Publie la clé device initiale comme active SEULEMENT si elle n'est pas vide/vide
    if (jr.pk_sig && jr.pk_kem && jr.device_id && jr.pk_sig.length > 0 && jr.pk_kem.length > 0) {
      app.log.info({ 
        groupId, 
        userId: jr.user_id, 
        deviceId: jr.device_id,
        sigLen: jr.pk_sig.length,
        kemLen: jr.pk_kem.length
      }, 'Activation des clés device existantes');
      
      await app.db.none(
        `INSERT INTO group_device_keys(group_id, user_id, device_id, pk_sig, pk_kem, key_version, status)
         VALUES($1,$2,$3,$4,$5,1,'active')
         ON CONFLICT (group_id,user_id,device_id) DO NOTHING`,
        [groupId, jr.user_id, jr.device_id, jr.pk_sig, jr.pk_kem]
      );
    } else {
      app.log.info({ groupId, userId: jr.user_id }, 'Pas de clés device valides à activer - utilisateur devra publier ses clés plus tard');
    }

    // Marque la requête comme acceptée
    await app.db.none(`UPDATE join_requests SET status='accepted', handled_by=$1 WHERE id=$2`, [approverId, rid]);

    // CORRECTION: Faire rejoindre l'utilisateur accepté à la room du groupe AVANT d'émettre l'événement
    app.io.in(`user:${jr.user_id}`).socketsJoin(`group:${groupId}`);
    app.log.info({ groupId, userId: jr.user_id }, 'User auto-joined group room after acceptance');

    // CORRECTION: Notifier tous les utilisateurs du groupe qu'un nouvel utilisateur a rejoint
      // SÉCURITÉ: Émettre un ping avec groupId (identifiant, pas de données sensibles)
      app.log.info({ groupId, userId: jr.user_id, approverId }, 'About to emit group:member_joined ping');
    app.io.to(`group:${groupId}`).emit('group:member_joined', { 
        type: 'group:member_joined',
        groupId: groupId,
        // Pas de userId, pas de approverId - juste l'identifiant du groupe
    });
      app.log.info({ groupId, userId: jr.user_id, approverId }, 'Group member joined ping sent (no sensitive data)');
    
      // SÉCURITÉ: Notifier spécifiquement l'utilisateur accepté qu'il a rejoint le groupe (ping minimal)
      app.log.info({ groupId, userId: jr.user_id }, 'About to emit group:joined ping to accepted user');
    
    // Vérifier si l'utilisateur est dans la room user:${userId}
    const userRoom = `user:${jr.user_id}`;
    const socketsInRoom = app.io.sockets.adapter.rooms.get(userRoom);
    app.log.info({ 
      groupId, 
      userId: jr.user_id, 
      userRoom, 
      socketsInRoom: socketsInRoom ? socketsInRoom.size : 0 
      }, 'Checking user room before emitting group:joined ping');
    
    app.io.to(`user:${jr.user_id}`).emit('group:joined', { 
        type: 'group:joined',
        groupId: groupId,
        // Pas de userId, pas de approverId - juste l'identifiant du groupe
    });
      app.log.info({ groupId, userId: jr.user_id }, 'User accepted - notified of group join (ping only)');

    // CORRECTION: Broadcaster la présence de l'utilisateur accepté aux autres membres du groupe
    if (app.services.presence && app.services.presence.broadcastUserPresence) {
      app.services.presence.broadcastUserPresence(jr.user_id, true, 1);
    } else {
      // Fallback: broadcaster manuellement
      app.io.to(`group:${groupId}`).emit('presence:update', { 
        userId: jr.user_id, 
        online: true, 
        count: 1 
      });
    }
    app.log.info({ groupId, userId: jr.user_id }, 'Presence broadcasted for accepted user');

    // CORRECTION: Mettre à jour le service de présence pour l'utilisateur accepté
    // Note: Le service de présence sera mis à jour automatiquement lors de la prochaine connexion
    // ou lors d'un événement de présence explicite

    return { ok: true };
  });

  // POST /api/groups/:id/join-requests { groupSigningPubKey, groupKEMPubKey }
  // Crée une demande de jointure avec les clés du groupe  
  app.post('/api/groups/:id/join-requests', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) }),
      body: Type.Object({
        groupSigningPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' })),
        groupKEMPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' })),
        deviceId: Type.Optional(Type.String()),
        deviceSigPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' })),
        deviceKemPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' }))
      })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: groupId } = req.params as any;
    const { groupSigningPubKey, groupKEMPubKey, deviceId, deviceSigPubKey, deviceKemPubKey } = req.body as any;

    // refuse si déjà membre
    const m = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [userId, groupId]);
    if (m.length) return reply.code(409).send({ error: 'already_member' });

    // 🚀 NOUVEAU: Utiliser les vraies clés device si fournies, sinon créer des placeholders
    let actualDeviceId = deviceId || '';
    let actualSigKey = deviceSigPubKey || '';
    let actualKemKey = deviceKemPubKey || '';
    
    // Si des clés device sont fournies, décoder en base64 pour PostgreSQL
    if (deviceSigPubKey && deviceKemPubKey && deviceId) {
      app.log.info({ groupId, userId, deviceId, sigLen: deviceSigPubKey.length, kemLen: deviceKemPubKey.length }, 'Demande avec clés device');
    } else {
      app.log.info({ groupId, userId }, 'Demande sans clés device (mode compatibilité)');
    }

    // Gérer le cas où les clés sont vides ou valides
    let jr;
    if (deviceSigPubKey && deviceKemPubKey && deviceId) {
      // Clés device valides fournies
      jr = await app.db.one(
        `INSERT INTO join_requests(group_id, user_id, device_id, pk_sig, pk_kem)
         VALUES($1,$2,$3,decode($4,'base64'),decode($5,'base64'))
         RETURNING id`,
        [groupId, userId, actualDeviceId, actualSigKey, actualKemKey]
      );
    } else {
      // Mode compatibilité avec clés vides
      jr = await app.db.one(
        `INSERT INTO join_requests(group_id, user_id, device_id, pk_sig, pk_kem)
         VALUES($1,$2,$3,E'\\x0000000000000000000000000000000000000000000000000000000000000000',E'\\x0000000000000000000000000000000000000000000000000000000000000000')
         RETURNING id`,
        [groupId, userId, actualDeviceId]
      );
    }
    
    reply.code(201); // Explicitement retourner le code 201 Created
    return { requestId: jr.id, status: 'pending' };
  });

  // GET /api/groups/:id/join-requests
  // Récupère les demandes de jointure pour un groupe (pour les admins/membres)
  app.get('/api/groups/:id/join-requests', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: groupId } = req.params as any;

    // Vérifie que l'utilisateur est membre du groupe
    const m = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [userId, groupId]);
    if (!m.length) return reply.code(403).send({ error: 'forbidden' });

    const rows = await app.db.any(
      `SELECT jr.id, jr.user_id, jr.device_id, jr.status, jr.created_at,
              u.email, u.username,
              COALESCE(COUNT(CASE WHEN jrv.vote = true THEN 1 END), 0)::int as "yesVotes",
              COALESCE(COUNT(CASE WHEN jrv.vote = false THEN 1 END), 0)::int as "noVotes"
         FROM join_requests jr
         JOIN users u ON u.id = jr.user_id
         LEFT JOIN join_request_votes jrv ON jrv.join_request_id = jr.id
        WHERE jr.group_id = $1 AND jr.status = 'pending'
        GROUP BY jr.id, jr.user_id, jr.device_id, jr.status, jr.created_at, u.email, u.username
        ORDER BY jr.created_at DESC`,
      [groupId]
    );
    
    return rows.map((row: { id: any; user_id: any; device_id: any; status: any; created_at: { toISOString: () => any; }; email: any; username: any; yesVotes: any; noVotes: any; }) => ({
      id: row.id,
      userId: row.user_id,
      deviceId: row.device_id,
      status: row.status,
      createdAt: row.created_at.toISOString(),
      email: row.email,
      username: row.username,
      yesVotes: row.yesVotes,
      noVotes: row.noVotes
    }));
  });

  // POST /api/groups/:id/join-requests/:reqId/vote
  // Permet aux membres du groupe de voter oui/non sur une demande de jointure
  app.post('/api/groups/:id/join-requests/:reqId/vote', {
    schema: {
      params: Type.Object({ 
        id: Type.String({ format: 'uuid' }),
        reqId: Type.String({ format: 'uuid' })
      }),
      body: Type.Object({
        vote: Type.Boolean()
      })
    }
  }, async (req, reply) => {
    const voterId = authenticatedUserId(req);
    const { id: groupId, reqId } = req.params as any;
    const { vote } = req.body as any;

    // Vérifie que le votant est membre du groupe
    const membership = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [voterId, groupId]);
    if (membership.length === 0) return reply.code(403).send({ error: 'forbidden' });

    // Vérifie que la demande existe et est en attente
    const jr = await app.db.oneOrNone(`SELECT id FROM join_requests WHERE id=$1 AND group_id=$2 AND status='pending'`, [reqId, groupId]);
    if (!jr) return reply.code(404).send({ error: 'request_not_found' });

    // Insère ou met à jour le vote (un utilisateur ne peut voter qu'une fois)
    await app.db.none(
      `INSERT INTO join_request_votes(join_request_id, user_id, vote)
       VALUES($1, $2, $3)
       ON CONFLICT (join_request_id, user_id) 
       DO UPDATE SET vote = $3, created_at = NOW()`,
      [reqId, voterId, vote]
    );

    // Récupère les compteurs mis à jour
    const counts = await app.db.one(
      `SELECT 
         COALESCE(COUNT(CASE WHEN vote = true THEN 1 END), 0)::int as "yesVotes",
         COALESCE(COUNT(CASE WHEN vote = false THEN 1 END), 0)::int as "noVotes"
        FROM join_request_votes
        WHERE join_request_id = $1`,
      [reqId]
    );

    return { yesVotes: counts.yesVotes, noVotes: counts.noVotes };
  });

  // POST /api/groups/:id/join-requests/:reqId/handle
  // Route pour accepter/rejeter une demande de jointure (SEUL LE CRÉATEUR PEUT DÉCIDER)
  app.post('/api/groups/:id/join-requests/:reqId/handle', {
    schema: {
      params: Type.Object({ 
        id: Type.String({ format: 'uuid' }),
        reqId: Type.String({ format: 'uuid' })
      }),
      body: Type.Object({
        action: Type.String({ enum: ['accept', 'reject'] })
      })
    }
  }, async (req, reply) => {
    const approverId = authenticatedUserId(req);
    const { id: groupId, reqId } = req.params as any;
    const { action } = req.body as any;

    // Vérifie que l'approver est membre du groupe
    const membership = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [approverId, groupId]);
    if (membership.length === 0) return reply.code(403).send({ error: 'forbidden' });

    // Vérifie que l'approver est le créateur du groupe
    const group = await app.db.oneOrNone(`SELECT creator_id FROM groups WHERE id=$1`, [groupId]);
    if (!group) return reply.code(404).send({ error: 'group_not_found' });
    if (group.creator_id !== approverId) {
      return reply.code(403).send({ error: 'only_creator_can_handle' });
    }

    if (action === 'accept') {
      // Code pour accepter la demande (identique à la route /accept)
      const jr = await app.db.one(`SELECT * FROM join_requests WHERE id=$1 AND group_id=$2 AND status='pending'`, [reqId, groupId]);
      
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
      await app.db.none(`UPDATE join_requests SET status='accepted', handled_by=$1 WHERE id=$2`, [approverId, reqId]);

      // CORRECTION: Faire rejoindre l'utilisateur accepté à la room du groupe AVANT d'émettre l'événement
      app.io.in(`user:${jr.user_id}`).socketsJoin(`group:${groupId}`);
      app.log.info({ groupId, userId: jr.user_id }, 'User auto-joined group room after acceptance');

      // SÉCURITÉ: Émettre uniquement un ping minimal pour les membres du groupe
      app.log.info({ groupId, userId: jr.user_id, approverId }, 'About to emit group:member_joined ping');
      app.io.to(`group:${groupId}`).emit('group:member_joined', { 
        type: 'group:member_joined',
        groupId: groupId,
        // Pas de userId, pas de approverId - juste l'identifiant du groupe
      });
      app.log.info({ groupId, userId: jr.user_id, approverId }, 'Group member joined ping sent (no sensitive data)');
      
      // SÉCURITÉ: Notifier spécifiquement l'utilisateur accepté qu'il a rejoint le groupe (ping minimal)
      app.log.info({ groupId, userId: jr.user_id }, 'About to emit group:joined ping to accepted user');
      
      // Vérifier si l'utilisateur est dans la room user:${userId}
      const userRoom = `user:${jr.user_id}`;
      const socketsInRoom = app.io.sockets.adapter.rooms.get(userRoom);
      app.log.info({ 
        groupId, 
        userId: jr.user_id, 
        userRoom, 
        socketsInRoom: socketsInRoom ? socketsInRoom.size : 0 
      }, 'Checking user room before emitting group:joined ping');
      
      app.io.to(`user:${jr.user_id}`).emit('group:joined', { 
        type: 'group:joined',
        groupId: groupId,
        // Pas de userId, pas de approverId - juste l'identifiant du groupe
      });
      app.log.info({ groupId, userId: jr.user_id }, 'User accepted - notified of group join');

      // CORRECTION: Broadcaster la présence de l'utilisateur accepté aux autres membres du groupe
      if (app.services.presence && app.services.presence.broadcastUserPresence) {
        app.services.presence.broadcastUserPresence(jr.user_id, true, 1);
      } else {
        // Fallback: broadcaster manuellement
        app.io.to(`group:${groupId}`).emit('presence:update', { 
          userId: jr.user_id, 
          online: true, 
          count: 1 
        });
      }
      app.log.info({ groupId, userId: jr.user_id }, 'Presence broadcasted for accepted user');
    } else if (action === 'reject') {
      // Code pour rejeter la demande (identique à la route /reject)
      await app.db.none(`UPDATE join_requests SET status='rejected', handled_by=$1 WHERE id=$2`, [approverId, reqId]);
    }

    reply.code(200); // Explicitement retourner le code 200 OK
    return { ok: true };
  });

  // POST /api/groups/:id/requests/:rid/reject
  // Route legacy - SEUL LE CRÉATEUR PEUT REJETER
  app.post('/api/groups/:id/requests/:rid/reject', {
    schema: {
      params: Type.Object({
        id: Type.String({ format: 'uuid' }),
        rid: Type.String({ format: 'uuid' })
      })
    }
  }, async (req, reply) => {
    const approverId = authenticatedUserId(req);
    const { id: groupId, rid } = req.params as any;

    const a = await app.db.any(`SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2`, [approverId, groupId]);
    if (!a.length) return reply.code(403).send({ error: 'forbidden' });

    // Vérifie que l'approver est le créateur du groupe
    const group = await app.db.oneOrNone(`SELECT creator_id FROM groups WHERE id=$1`, [groupId]);
    if (!group) return reply.code(404).send({ error: 'group_not_found' });
    if (group.creator_id !== approverId) {
      return reply.code(403).send({ error: 'only_creator_can_handle' });
    }

    await app.db.none(`UPDATE join_requests SET status='rejected', handled_by=$1 WHERE id=$2`, [approverId, rid]);
    return { ok: true };
  });
}
