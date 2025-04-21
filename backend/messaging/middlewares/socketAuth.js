export function socketAuthMiddleware(io, fastify) {
  io.use(async (socket, next) => {
    try {
      const token =
        socket.handshake.auth.token ||
        socket.handshake.headers['authorization']?.split(' ')[1];

      if (!token) {
        return next(new Error('Authentication token missing'));
      }

      const decoded = await fastify.jwt.verify(token);
      socket.user = decoded;
      next();
    } catch (err) {
      console.error('[SocketAuth]', err.message);
      return next(new Error('Invalid or expired token'));
    }
  });
}