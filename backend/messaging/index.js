// /app/backend/messaging/index.js

import express from 'express';
import http from 'http';
import { Server } from 'socket.io';
import { socketAuthMiddleware } from './middlewares/socketAuth.js';
import { groupRoutes } from './routes/groups.js';
import { conversationRoutes } from './routes/conversations.js';

const app = express();
app.use(express.json());

const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  }
});

socketAuthMiddleware(io);

groupRoutes(app);         
conversationRoutes(app);  

io.on('connection', (socket) => {
  console.log('Authenticated user connected:', socket.user.id);

  socket.on('message:send', async (payload) => {
    // Validate and save message payload (AES encrypted message + keys)
    // payload = { conversationId, encryptedMessage, encryptedKeys }
    // encryptedKeys = { user_id1: rsa(AES_key), user_id2: rsa(AES_key), ... }

    const { conversationId, encryptedMessage, encryptedKeys } = payload;
    const senderId = socket.user.id;

    try {
      await app.pg.query(
        'INSERT INTO messages (conversation_id, sender_id, encrypted_message, encrypted_keys) VALUES ($1, $2, $3, $4)',
        [conversationId, senderId, encryptedMessage, encryptedKeys]
      );
      io.to(conversationId).emit('message:new', { senderId, encryptedMessage, encryptedKeys });
    } catch (err) {
      console.error('[message:send]', err);
      socket.emit('error', 'Message could not be stored');
    }
  });
});

app.get('/health', (req, res) => res.send('Messaging OK'));

server.listen(process.env.PORT || 3001, () => {
  console.log(`Messaging listening on port ${process.env.PORT || 3001}`);
});
