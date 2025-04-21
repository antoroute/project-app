import express from 'express';
import http from 'http';
import { Server } from 'socket.io';
import { socketAuthMiddleware } from './middlewares/socketAuth.js';

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  }
});

// Middleware JWT centralisé
socketAuthMiddleware(io);

io.on('connection', (socket) => {
  console.log('✅ Authenticated user connected:', socket.user.email);

  socket.on('message', (data) => {
    console.log(`[${socket.user.email}] says:`, data);
  });

  socket.on('disconnect', () => {
    console.log(`User ${socket.user.email} disconnected`);
  });
});

app.get('/health', (req, res) => res.send('Messaging OK'));

server.listen(process.env.PORT || 3001, () => {
  console.log(`Messaging listening on port ${process.env.PORT || 3001}`);
});
