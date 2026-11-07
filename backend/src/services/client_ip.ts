import { Request } from 'express';
import { isIP } from 'net';

const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

/**
 * Client IP behind nginx and Cloudflare.
 *
 * nginx rewrites X-Real-IP from the real socket, or from CF-Connecting-IP when
 * the peer is a Cloudflare edge (the real_ip module is configured with the CF
 * ranges). The app trusts that header only when the TCP peer is the local
 * nginx, so a direct connection to the origin cannot spoof it.
 */
export const clientIp = (req: Request): string => {
  const peer = req.socket.remoteAddress || '';
  if (!LOOPBACK.has(peer)) return peer || req.ip || 'unknown';
  const real = req.headers['x-real-ip'];
  if (typeof real === 'string' && isIP(real)) return real;
  return req.ip || peer || 'unknown';
};