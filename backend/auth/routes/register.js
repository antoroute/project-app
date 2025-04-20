import bcrypt from 'bcrypt';

function isValidRSA4096(publicKey) {
  return (
    typeof publicKey === 'string' &&
    publicKey.includes('-----BEGIN PUBLIC KEY-----') &&
    publicKey.includes('-----END PUBLIC KEY-----') &&
    publicKey.length >= 800 // RSA 4096 = ~800 à 900 caractères base64 encodé
  );
}

export function registerRoutes(fastify) {
  fastify.post('/register', {
    schema: {
      body: {
        type: 'object',
        required: ['email', 'password', 'publicKey'],
        properties: {
          email: { type: 'string', format: 'email' },
          password: { type: 'string', minLength: 6 },
          publicKey: { type: 'string', minLength: 800 }
        }
      }
    }
  }, async (req, reply) => {
    const { email, password, publicKey } = req.body;

    // Vérification manuelle du format de la clé publique RSA 4096
    if (!isValidRSA4096(publicKey)) {
      return reply.code(400).send({ error: 'Invalid RSA 4096 public key format' });
    }

    try {
      // Vérifie si l'utilisateur existe déjà
      const existing = await fastify.pg.query('SELECT 1 FROM users WHERE email = $1', [email]);
      if (existing.rowCount > 0) {
        return reply.code(409).send({ error: 'Email already registered' });
      }

      // Hash sécurisé avec sel intégré
      const hashed = await bcrypt.hash(password, 12); // 12 = plus sécurisé

      await fastify.pg.query(
        'INSERT INTO users (email, password, public_key) VALUES ($1, $2, $3)',
        [email, hashed, publicKey]
      );

      return reply.code(201).send({ message: 'User registered' });

    } catch (err) {
      req.log.error(err);
      return reply.code(500).send({ error: 'Server error during registration' });
    }
  });
}
