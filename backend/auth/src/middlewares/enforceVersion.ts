import type { FastifyPluginAsync } from 'fastify';
import fp from 'fastify-plugin';

// Autoriser ces routes sans X-Client-Version
const ALLOWLIST = [
  /^\/health$/,            // healthcheck (Docker/infra)
  /^\/auth\/login$/,       // login (pas de client encore)
  /^\/auth\/register$/,    // register
  /^\/auth\/refresh$/,     // refresh token
  /^\/auth\/logout$/,      // logout
];

const enforceVersion: FastifyPluginAsync = async (app) => {
  app.addHook('onRequest', async (req, reply) => {
    // Préflight CORS → autoriser
    if (req.method === 'OPTIONS') return;

    // Normaliser l'URL sans querystring
    const url = (req.raw.url || '/').split('?')[0];

    // Whitelist : laisser passer
    if (ALLOWLIST.some((rx) => rx.test(url))) return;

    // Lire la version client
    const v = String(req.headers['x-client-version'] || '').trim();
    const major = parseInt(v.split('.')[0] || '0', 10);

    // Bloquer si absent ou < 2
    if (!major || major < 2) {
      return reply.code(426).send({ error: 'client_update_required', min: '2.0.0' });
    }
  });
};

export default fp(enforceVersion);
