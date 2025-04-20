export function verifyJWT(fastify) {
    return async function (req, reply) {
      try {
        await req.jwtVerify();
      } catch (err) {
        reply.send(err);
      }
    };
  }  