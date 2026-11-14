import pool from '../config/database';

/**
 * Журнал обращений к API.
 *
 * Запись не должна добавлять задержку к ответу: middleware кладёт строку в
 * очередь, а запись в базу уходит пачкой раз в несколько секунд. Один INSERT
 * на пачку вместо одного на запрос — при всплеске (атака, обход каталога)
 * количество обращений к базе не растёт линейно с трафиком.
 *
 * Ошибки записи проглатываются: журнал вспомогательный, он не имеет права
 * уронить обработчик или превратить 200 в 500.
 */

export interface VisitEntry {
  ip: string;
  userId?: string | null;
  deviceId?: string | null;
  platform?: string | null;
  appVersion?: string | null;
  method: string;
  path: string;
  status: number;
  userAgent?: string | null;
  durationMs: number;
}

export type VisitExecutor = (
  sql: string,
  params: unknown[],
) => Promise<unknown>;

const COLUMNS = [
  'ip',
  'user_id',
  'device_id',
  'platform',
  'app_version',
  'method',
  'path',
  'status',
  'user_agent',
  'duration_ms',
] as const;

/** Пределы полей: строка пути или User-Agent может быть любого размера. */
export const LIMITS = {
  ip: 45,
  deviceId: 64,
  platform: 32,
  appVersion: 32,
  method: 16,
  path: 512,
  userAgent: 300,
} as const;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DEVICE_RE = /^[A-Za-z0-9._:-]{1,64}$/;

const cut = (value: string | null | undefined, max: number): string | null => {
  if (value == null) return null;
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  return trimmed.length > max ? trimmed.slice(0, max) : trimmed;
};

/** UUID пользователя пишем только валидным: мусор в колонке ломает сравнения. */
export const normalizeUserId = (value: unknown): string | null => {
  const raw = cut(typeof value === 'string' ? value : null, 36);
  return raw && UUID_RE.test(raw) ? raw.toLowerCase() : null;
};

/** Идентификатор устройства от клиента: без пробелов и управляющих символов. */
export const normalizeDeviceId = (value: unknown): string | null => {
  const raw = typeof value === 'string' ? value.trim() : null;
  return raw && DEVICE_RE.test(raw) ? raw : null;
};

/** Выражение для одной строки пачки: $1..$10, $11..$20, ... */
const rowPlaceholders = (rowIndex: number): string =>
  `(${COLUMNS.map((_, c) => `$${rowIndex * COLUMNS.length + c + 1}`).join(', ')})`;

export const buildInsert = (
  rows: number,
): string =>
  `INSERT INTO request_visits (${COLUMNS.join(', ')}) VALUES ${Array.from(
    { length: rows },
    (_, i) => rowPlaceholders(i),
  ).join(', ')}`;

export const rowParams = (entry: VisitEntry): unknown[] => [
  cut(entry.ip, LIMITS.ip),
  normalizeUserId(entry.userId),
  normalizeDeviceId(entry.deviceId),
  cut(entry.platform, LIMITS.platform),
  cut(entry.appVersion, LIMITS.appVersion),
  cut(entry.method, LIMITS.method) ?? 'GET',
  cut(entry.path, LIMITS.path) ?? '/',
  Number.isFinite(entry.status) ? entry.status : null,
  cut(entry.userAgent, LIMITS.userAgent),
  Number.isFinite(entry.durationMs) ? Math.max(0, Math.round(entry.durationMs)) : null,
];

export interface VisitAuditOptions {
  /** Размер пачки, после которого пишем, не дожидаясь таймера. */
  batchLimit?: number;
  /** Как часто сбрасывать накопленное. */
  flushMs?: number;
}

export interface VisitAudit {
  record(entry: VisitEntry): void;
  flush(): Promise<void>;
  pending(): number;
  dispose(): void;
}

export function createVisitAudit(
  execute: VisitExecutor,
  options: VisitAuditOptions = {},
): VisitAudit {
  const batchLimit = options.batchLimit ?? 200;
  const flushMs = options.flushMs ?? 2000;
  let queue: VisitEntry[] = [];
  let timer: NodeJS.Timeout | null = null;
  let disposed = false;

  const write = async (rows: VisitEntry[]): Promise<void> => {
    const params = rows.flatMap(rowParams);
    try {
      await execute(buildInsert(rows.length), params);
    } catch (error) {
      // Журнал не критичен для ответа; но молчать нельзя — иначе «данных
      // нет» будет выглядеть как «никто не заходил».
      console.error('request audit write failed:', (error as Error)?.message);
    }
  };

  const flush = async (): Promise<void> => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    while (queue.length > 0) {
      const batch = queue.splice(0, batchLimit);
      await write(batch);
    }
  };

  const schedule = (): void => {
    if (timer || disposed) return;
    timer = setTimeout(() => {
      timer = null;
      void flush();
    }, flushMs);
    // Не держим процесс живым из-за таймера журнала.
    timer.unref?.();
  };

  const record = (entry: VisitEntry): void => {
    if (disposed) return;
    queue.push(entry);
    if (queue.length >= batchLimit) {
      void flush();
      return;
    }
    schedule();
  };

  const dispose = (): void => {
    disposed = true;
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
  };

  return {
    record,
    flush,
    pending: () => queue.length,
    dispose,
  };
}

/** Рабочий журнал приложения: пишет через общий пул. */
export const visitAudit = createVisitAudit((sql, params) =>
  pool.query(sql, params),
);

/** Возраст записей журнала: старые сутки не нужны, база на VPS маленькая. */
export const VISIT_RETENTION_DAYS = 180;

/**
 * Чистка журнала. Удаляет пачками: один `DELETE` на сотни тысяч строк держал
 * бы блокировки и раздувал WAL.
 */
export async function purgeOldVisits(
  days: number = VISIT_RETENTION_DAYS,
  executor: VisitExecutor = (sql, params) => pool.query(sql, params),
): Promise<number> {
  let removed = 0;
  for (;;) {
    const result = (await executor(
      `DELETE FROM request_visits
       WHERE id IN (
         SELECT id FROM request_visits
         WHERE created_at < now() - ($1 || ' days')::interval
         LIMIT 5000
       )`,
      [String(days)],
    )) as { rowCount?: number } | undefined;
    const count = result?.rowCount ?? 0;
    removed += count;
    if (count < 5000) break;
  }
  return removed;
}

export function startVisitRetentionSweep(
  intervalMs: number = 24 * 60 * 60 * 1000,
): void {
  const run = () => {
    purgeOldVisits().catch((error) =>
      console.error('request audit purge failed:', (error as Error)?.message),
    );
  };
  // Первый прогон не в момент старта: пусть сервер сначала поднимется.
  setTimeout(run, 10 * 60 * 1000).unref?.();
  setInterval(run, intervalMs).unref?.();
}