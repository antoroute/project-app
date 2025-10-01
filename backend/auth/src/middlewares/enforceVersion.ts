import type { FastifyInstance } from 'fastify';

export default async function enforceVersion(app: FastifyInstance) {
  app.addHook('onRequest', async (req: any, reply: any) => {
    const v = String(req.headers['x-client-version'] || '');
    const major = parseInt(v.split('.')[0] || '0', 10);
    if (!major || major < 2) {
      return reply.code(426).send({ error: 'client_update_required', min: '2.0.0' });
    }
  });
}
