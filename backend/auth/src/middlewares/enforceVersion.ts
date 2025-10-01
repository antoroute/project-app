import { FastifyPluginAsync } from 'fastify';
import fp from 'fastify-plugin';

const enforceVersion: FastifyPluginAsync = async (app) => {
  app.addHook('onRequest', async (req, reply) => {
    const v = String(req.headers['x-client-version'] || '');
    const major = parseInt(v.split('.')[0] || '0', 10);
    if (!major || major < 2) {
      return reply.code(426).send({ error: 'client_update_required', min: '2.0.0' });
    }
  });
};

export default fp(enforceVersion);
