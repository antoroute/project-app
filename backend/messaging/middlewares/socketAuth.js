import jwt from 'jsonwebtoken';

export function socketAuthMiddleware(io) {
  io.use((socket, next) => {
    const token = socket.handshake.auth.token || socket.handshake.headers['authorization']?.split(' ')[1];

    if (!token) {
      return next(new Error('Authentication token missing'));
    }

    try {
      const decoded = jwt.verify(token, process.env.JWT_SECRET);
      socket.user = decoded; // Injecte les données utilisateur
      next();
    } catch (err) {
      console.error('[SocketAuth]', err.message);
      return next(new Error('Invalid or expired token'));
    }
  });
}
