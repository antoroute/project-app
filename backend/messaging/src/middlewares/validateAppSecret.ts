import type { FastifyPluginAsync } from 'fastify';
import fp from 'fastify-plugin';

// 🔐 App Secret - DOIT correspondre à celui dans l'app Flutter
// Utilise la variable d'environnement APP_SECRET (comme JWT_SECRET)
const APP_SECRET = process.env.APP_SECRET || 'kavalek_app_2024_secure_secret_key_v2';

// Routes qui ne nécessitent pas le App Secret (health check, etc.)
const ALLOWLIST = [
  /^\/health$/,
  /^\/socket/, // Socket.IO handshake
];

const validateAppSecret: FastifyPluginAsync = async (app) => {
  app.addHook('onRequest', async (req, reply) => {
    // Ignorer OPTIONS (CORS preflight)
    if (req.method === 'OPTIONS') return;

    const url = (req.raw.url || '/').split('?')[0];
    
    // Vérifier si la route est dans la allowlist
    if (ALLOWLIST.some((rx) => rx.test(url))) return;

    // Récupérer le secret depuis les headers
    const providedSecret = String(req.headers['x-app-secret'] || '').trim();

    // Vérifier que le secret correspond
    if (providedSecret !== APP_SECRET) {
      app.log.warn({
        url: req.url,
        ip: req.ip,
        userAgent: req.headers['user-agent'],
        providedSecret: providedSecret ? '***' : '(missing)',
      }, 'Unauthorized API access attempt - invalid app secret');
      
      return reply.code(403).send({ 
        error: 'forbidden',
        message: 'Invalid or missing app secret. This API is only accessible from the official application.' 
      });
    }

    // Secret valide, continuer
    app.log.debug({ url: req.url }, 'App secret validated');
  });
};

export default fp(validateAppSecret);

