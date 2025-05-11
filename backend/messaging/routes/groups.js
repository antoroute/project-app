import { createVerify } from 'crypto';

export function groupRoutes(fastify) {
  const pool = fastify.pg;

  // Créer un groupe
  fastify.post('/groups', {
    preHandler: fastify.authenticate,
    schema: { body:{type:'object',required:['name','publicKeyGroup'],properties:{name:{type:'string'},publicKeyGroup:{type:'string',minLength:700}}} }
  }, async (request, reply) => {
    const { name, publicKeyGroup } = request.body;
    const userId = request.user.id;
    try {
      const groupRes = await pool.query(
        'INSERT INTO groups (name, creator_id) VALUES ($1,$2) RETURNING id',
        [name,userId]
      );
      const groupId = groupRes.rows[0].id;
      await pool.query(
        'INSERT INTO user_groups (user_id,group_id,public_key_group) VALUES($1,$2,$3)',
        [userId,groupId,publicKeyGroup]
      );
      return reply.code(201).send({ groupId });
    } catch (err) {
      request.log.error(err);
      return reply.code(400).send({ error:'Group creation failed' });
    }
  });

  // ─── Lister les groupes de l'utilisateur ────────────────────────────────────
  fastify.get('/groups', {
    preHandler: fastify.authenticate
  }, async (request, reply) => {
    const userId = request.user.id;
    try {
      const res = await fastify.pg.query(
        `SELECT g.id   AS "groupId",
                g.name,
                g.creator_id  AS "creatorId",
                g.created_at  AS "createdAt"
          FROM user_groups ug
          JOIN groups g ON g.id = ug.group_id
          WHERE ug.user_id = $1
      ORDER BY g.created_at DESC`,
        [userId]
      );
      return reply.send(res.rows);
    } catch (err) {
      request.log.error(err);
      return reply.code(500).send({ error: 'Failed to load groups' });
    }
  });

  // Détails d’un groupe
  fastify.get('/groups/:id', {
    preHandler: fastify.authenticate,
    schema: { params:{type:'object',required:['id'],properties:{id:{type:'string',format:'uuid'}}} }
  }, async (request, reply) => {
    const groupId = request.params.id;
    const userId  = request.user.id;
    const isMember = await pool.query(
      'SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2',
      [userId,groupId]
    );
    if (isMember.rowCount===0) return reply.code(403).send({ error:'Forbidden: not a group member' });
    try {
      const res = await pool.query('SELECT id,name,creator_id FROM groups WHERE id=$1',[groupId]);
      if (res.rowCount===0) return reply.code(404).send({ error:'Group not found' });
      return reply.send(res.rows[0]);
    } catch (err) {
      request.log.error(err);
      return reply.code(500).send({ error:'Failed to fetch group' });
    }
  });

  // Demande d’adhésion
  fastify.post('/groups/:id/join-requests', {
    preHandler: fastify.authenticate,
    schema: { params:{type:'object',required:['id'],properties:{id:{type:'string',format:'uuid'}}}, body:{type:'object',required:['publicKeyGroup'],properties:{publicKeyGroup:{type:'string',minLength:700}}} }
  }, async (request, reply) => {
    const groupId = request.params.id;
    const userId = request.user.id;
    const { publicKeyGroup } = request.body;
    const grpRes = await pool.query('SELECT 1 FROM groups WHERE id=$1',[groupId]);
    if (grpRes.rowCount===0) return reply.code(404).send({ error:'Group not found' });
    const pend = await pool.query(
      "SELECT 1 FROM join_requests WHERE user_id=$1 AND group_id=$2 AND status='pending'",
      [userId,groupId]
    );
    if (pend.rowCount>0) return reply.code(409).send({ error:'You already have a pending join request' });
    try {
      const jr = await pool.query(
        'INSERT INTO join_requests (group_id,user_id,public_key_group) VALUES($1,$2,$3) RETURNING id,created_at',
        [groupId,userId,publicKeyGroup]
      );
      return reply.code(201).send({ requestId:jr.rows[0].id, createdAt:jr.rows[0].created_at });
    } catch (err) {
      request.log.error(err);
      return reply.code(500).send({ error:'Failed to create join request' });
    }
  });

  // Lister demandes en attente
  fastify.get('/groups/:id/join-requests',{ preHandler:fastify.authenticate, schema:{params:{type:'object',required:['id'],properties:{id:{type:'string',format:'uuid'}}}}},async(request,reply)=>{
    const groupId=request.params.id; const userId=request.user.id;
    const isMember=await pool.query('SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2',[userId,groupId]);
    if(isMember.rowCount===0) return reply.code(403).send({error:'Forbidden'});
    try{
      const res=await pool.query(
        `SELECT jr.id, jr.user_id AS "userId", u.username, jr.created_at,
                 jr.public_key_group AS "publicKeyGroup",
                 COUNT(*) FILTER(WHERE jrv.vote=TRUE) AS "yesVotes",
                 COUNT(*) FILTER(WHERE jrv.vote=FALSE)AS "noVotes"
           FROM join_requests jr
           JOIN users u ON u.id=jr.user_id
      LEFT JOIN join_request_votes jrv ON jrv.request_id=jr.id
          WHERE jr.group_id=$1 AND jr.status='pending'
       GROUP BY jr.id,jr.user_id,u.username,jr.created_at,jr.public_key_group`,
        [groupId]
      ); return reply.send(res.rows);
    } catch(err){ request.log.error(err); return reply.code(500).send({error:'Failed to list join requests'});}  
  });

  // Voter
  fastify.post('/groups/:id/join-requests/:reqId/vote',{preHandler:fastify.authenticate, schema:{params:{type:'object',required:['id','reqId'],properties:{id:{type:'string',format:'uuid'},reqId:{type:'string',format:'uuid'}}},body:{type:'object',required:['vote'],properties:{vote:{type:'boolean'}}}}},async(request,reply)=>{
    const {id:groupId,reqId:requestId} = request.params; const userId=request.user.id; const vote=request.body.vote;
    const isMember=await pool.query('SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2',[userId,groupId]);
    if(isMember.rowCount===0) return reply.code(403).send({error:'Forbidden'});
    const jrCheck=await pool.query('SELECT 1 FROM join_requests WHERE id=$1 AND group_id=$2',[requestId,groupId]);
    if(jrCheck.rowCount===0) return reply.code(404).send({error:'Join request not found'});
    try{
      await pool.query(
        `INSERT INTO join_request_votes(request_id,voter_id,vote)
         VALUES($1,$2,$3)
         ON CONFLICT(request_id,voter_id)
         DO UPDATE SET vote=EXCLUDED.vote,created_at=CURRENT_TIMESTAMP`,
        [requestId,userId,vote]
      );
      const counts=await pool.query(
        `SELECT COUNT(*) FILTER(WHERE vote=TRUE) AS "yesVotes",
                COUNT(*) FILTER(WHERE vote=FALSE) AS "noVotes"
           FROM join_request_votes WHERE request_id=$1`,
        [requestId]
      );
      return reply.send(counts.rows[0]);
    }catch(err){request.log.error(err);return reply.code(500).send({error:'Failed to record vote'});}  
  });

  // Handle join requests
  fastify.post('/groups/:id/join-requests/:reqId/handle',{preHandler:fastify.authenticate, schema:{params:{type:'object',required:['id','reqId'],properties:{id:{type:'string',format:'uuid'},reqId:{type:'string',format:'uuid'}}},body:{type:'object',required:['action'],properties:{action:{type:'string',enum:['accept','reject']}}}}},async(request,reply)=>{
    const {id:groupId,reqId:requestId} = request.params; const userId=request.user.id; const action=request.body.action;
    const gRes=await pool.query('SELECT creator_id FROM groups WHERE id=$1',[groupId]);
    if(gRes.rowCount===0) return reply.code(404).send({error:'Group not found'});
    if(gRes.rows[0].creator_id!==userId) return reply.code(403).send({error:'Only creator may handle requests'});
    const jrRes=await pool.query('SELECT user_id,public_key_group,status FROM join_requests WHERE id=$1 AND group_id=$2',[requestId,groupId]);
    if(jrRes.rowCount===0) return reply.code(404).send({error:'Join request not found'});
    const jr=jrRes.rows[0]; if(jr.status!=='pending') return reply.code(400).send({error:'Request already handled'});
    const newStatus = action==='accept'?'accepted':'rejected';
    try{
      await pool.query('UPDATE join_requests SET status=$1,handled_by=$2 WHERE id=$3',[newStatus,userId,requestId]);
      if(action==='accept'){
        await pool.query(
          `INSERT INTO user_groups(user_id,group_id,public_key_group)
           VALUES($1,$2,$3)
           ON CONFLICT(user_id,group_id)
           DO UPDATE SET public_key_group=EXCLUDED.public_key_group`,
          [jr.user_id,groupId,jr.public_key_group]
        );
        fastify.io.to(`group:${groupId}`).emit('group:user_added',{groupId,userId:jr.user_id});
        fastify.io.to(`user:${jr.user_id}`).emit('group:joined',{groupId});
      }
      return reply.send({handled:true});
    }catch(err){request.log.error(err);return reply.code(500).send({error:'Failed to handle join request'});}  
  });

  // Lister membres du groupe
  fastify.get('/groups/:id/members',{preHandler:fastify.authenticate, schema:{params:{type:'object',required:['id'],properties:{id:{type:'string',format:'uuid'}}}}},async(request,reply)=>{
    const groupId=request.params.id; const userId=request.user.id;
    const isMember=await pool.query('SELECT 1 FROM user_groups WHERE user_id=$1 AND group_id=$2',[userId,groupId]);
    if(isMember.rowCount===0) return reply.code(403).send({error:'Forbidden'});
    try{
      const membersRes=await pool.query(
        `SELECT u.id AS "userId",u.email,u.username,ug.public_key_group AS "publicKeyGroup"
           FROM user_groups ug JOIN users u ON u.id=ug.user_id
          WHERE ug.group_id=$1`,
        [groupId]
      );
      return reply.send(membersRes.rows);
    }catch(err){request.log.error(err);return reply.code(500).send({error:'Failed to fetch members'});}  
  });
}