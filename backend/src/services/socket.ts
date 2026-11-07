import { Server as SocketIOServer, Socket } from 'socket.io';
import { Server as HttpServer } from 'http';
import jwt from 'jsonwebtoken';
import pool from '../config/database';
import { validate as uuidValidate } from 'uuid';

let io: SocketIOServer | null = null;

export const initSocket = (server: HttpServer): SocketIOServer => {
  const allowedOrigins = (process.env.CORS_ORIGINS || '')
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);

  io = new SocketIOServer(server, {
    cors: {
      // Native clients send no Origin; browser clients must match the same
      // allowlist as the HTTP API (SEC-03).
      origin: (origin, callback) => {
        if (!origin) return callback(null, true);
        if (allowedOrigins.length === 0 && process.env.NODE_ENV !== 'production') {
          return callback(null, true);
        }
        if (allowedOrigins.includes(origin)) return callback(null, true);
        return callback(new Error('Not allowed by CORS'));
      },
      methods: ['GET', 'POST'],
    },
  });

  io.use((socket, next) => {
    const token = socket.handshake.auth?.token || socket.handshake.query?.token;
    if (!token) {
      return next(new Error('Authentication error: No token provided'));
    }
    // Без секрета проверять подпись нечем. Фоллбэк 'fallback_secret' означал,
    // что при пустом JWT_SECRET любой, кто знает это слово, получает сокет
    // любого пользователя.
    const jwtSecret = process.env.JWT_SECRET;
    if (!jwtSecret) {
      console.error('[socket] JWT_SECRET is not set — realtime is disabled');
      return next(new Error('Authentication error: Server is not configured'));
    }

    try {
      const decoded = jwt.verify(token, jwtSecret, { algorithms: ['HS256'] }) as { id: string };
      socket.data.userId = decoded.id;
      next();
    } catch (err) {
      next(new Error('Authentication error: Invalid token'));
    }
  });

  io.on('connection', (socket: Socket) => {
    const userId = socket.data.userId;
    console.log(`[Socket] User connected: ${userId}`);

    // Join personal room for personal notifications
    socket.join(`user_${userId}`);

    socket.on('join_post', async (postId: string) => {
      if (!postId || typeof postId !== 'string' || !uuidValidate(postId)) return;
      try {
        const post = await pool.query(
          'SELECT author_id, is_active FROM author_posts WHERE id = $1',
          [postId],
        );
        if (post.rows.length === 0 || post.rows[0].is_active !== true) return;
        const blocked = await pool.query(
          'SELECT 1 FROM user_blocks WHERE user_id = $1 AND blocked_id = $2',
          [userId, post.rows[0].author_id],
        );
        if (blocked.rows.length > 0) return;
        socket.join(`post_${postId}`);
        console.log(`[Socket] User ${userId} joined post_${postId}`);
      } catch (err) {
        console.error('[Socket] join_post authorization failed:', err);
      }
    });

    socket.on('leave_post', (postId: string) => {
      if (postId && typeof postId === 'string') {
        socket.leave(`post_${postId}`);
        console.log(`[Socket] User ${userId} left post_${postId}`);
      }
    });

    socket.on('disconnect', () => {
      console.log(`[Socket] User disconnected: ${userId}`);
    });
  });

  return io;
};

export const getIO = (): SocketIOServer => {
  if (!io) {
    throw new Error('Socket.io not initialized!');
  }
  return io;
};
