import type { FastifyPluginAsync } from 'fastify';
import fp from 'fastify-plugin';

const ALLOWLIST = [
  /^\/health$/,    // health
  /^\/socket/,     // handshake Socket.IO (path '/socket')
];

const enforceVersion: FastifyPluginAsync = async (app) => {
  app.addHook('onRequest', async (req, reply) => {
    if (req.method === 'OPTIONS') return;

    const url = (req.raw.url || '/').split('?')[0];
    if (ALLOWLIST.some((rx) => rx.test(url))) return;

    const v = String(req.headers['x-client-version'] || '').trim();
    const major = parseInt(v.split('.')[0] || '0', 10);

    if (!major || major < 2) {
      return reply.code(426).send({ error: 'client_update_required', min: '2.0.0' });
    }
  });
};

export default fp(enforceVersion);
