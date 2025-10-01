// Refuse les clients < v2 (cohérence avec le big-bang crypto v2)
import { FastifyInstance } from 'fastify';
import fp from 'fastify-plugin';

export default fp(async function (app: FastifyInstance) {
  app.addHook('onRequest', async (req, reply) => {
    const v = String(req.headers['x-client-version'] || '');
    // attend un format "2.x.y" ou supérieur
    const major = parseInt(v.split('.')[0] || '0', 10);
    if (!major || major < 2) {
      return reply.code(426).send({ error: 'client_update_required', min: '2.0.0' });
    }
  });
});
