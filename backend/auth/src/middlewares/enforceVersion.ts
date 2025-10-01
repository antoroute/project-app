import fp from 'fastify-plugin';
import type { FastifyInstance } from 'fastify';

export default fp(async function (app: FastifyInstance) {
  app.addHook('onRequest', async (req: any, reply: any) => {
    const v = String(req.headers['x-client-version'] || '');
    const major = parseInt(v.split('.')[0] || '0', 10);
    if (!major || major < 2) {
      return reply.code(426).send({ error: 'client_update_required', min: '2.0.0' });
    }
  });
});
