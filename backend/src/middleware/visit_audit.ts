import { Request, Response, NextFunction } from 'express';

import { clientIp } from '../services/client_ip';
import { visitAudit, type VisitEntry } from '../services/visit_audit';
import type { AuthRequest } from './auth';

/**
 * Журнал посещений API.
 *
 * Строка собирается на `finish`, а не на входе: к этому моменту роут уже
 * разобрал токен и положил `req.user`, известен статус ответа и время.
 * Запись идёт через буфер ([visitAudit]) — ответ её не ждёт.
 *
 * Статика и загрузки не пишутся: там одна картинка на кадр и десятки тысяч
 * строк, а для разбора атак нужны обращения к API.
 */

const SKIP_PREFIXES = ['/uploads/', '/static/', '/.well-known/'];

export const shouldAudit = (path: string): boolean => {
  if (path === '/favicon.ico' || path === '/robots.txt') return false;
  return !SKIP_PREFIXES.some((prefix) => path.startsWith(prefix));
};

const headerValue = (value: unknown): string | null => {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return String(value[0] ?? '') || null;
  return null;
};

/** Запись журнала по завершённому запросу. Вынесена для тестов. */
export const visitEntryFor = (
  req: Request,
  status: number,
  durationMs: number,
): VisitEntry | null => {
  const path = req.originalUrl || req.url || '/';
  if (!shouldAudit((req.path || path).split('?')[0])) return null;
  const user = (req as AuthRequest).user;
  const userId = typeof user?.id === 'string' ? user.id : null;
  return {
    ip: clientIp(req),
    userId,
    deviceId: headerValue(req.headers['x-device-id']),
    platform: headerValue(req.headers['x-client-platform']),
    appVersion: headerValue(req.headers['x-client-version']),
    method: req.method,
    path,
    status,
    userAgent: headerValue(req.headers['user-agent']),
    durationMs,
  };
};

export function visitAuditMiddleware(
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  const startedAt = process.hrtime.bigint();
  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    const entry = visitEntryFor(req, res.statusCode, durationMs);
    if (entry) visitAudit.record(entry);
  });
  next();
}