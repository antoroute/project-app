import type { FastifyPluginAsync } from 'fastify';
import fp from 'fastify-plugin';

interface ValidateAppSecretOptions {
  appSecret: string;
}

// Routes publiques qui ne nécessitent pas le App Secret
// Login et Register sont publics pour permettre l'inscription/connexion
const PUBLIC_ROUTES = [
  /^\/health$/,
  /^\/auth\/login$/,
  /^\/auth\/register$/,
];

const validateAppSecret: FastifyPluginAsync<ValidateAppSecretOptions> = async (app, options) => {
  app.addHook('onRequest', async (req, reply) => {
    // Ignorer OPTIONS (CORS preflight)
    if (req.method === 'OPTIONS') return;

    const url = (req.raw.url || '/').split('?')[0];
    
    // Vérifier si la route est publique
    if (PUBLIC_ROUTES.some((rx) => rx.test(url))) return;

    // Récupérer le secret depuis les headers
    const providedSecret = String(req.headers['x-app-secret'] || '').trim();

    // Vérifier que le secret correspond
    if (providedSecret !== options.appSecret) {
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
