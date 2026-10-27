/**
 * Три уровня каталога маркета.
 *
 * 1 — лучшие: отобраны вручную;
 * 2 — прошедшие модерацию, не демо;
 * 3 — демо, самый низ каталога.
 *
 * Уровень и флаг демо связаны: демо всегда 3, уровни 1–2 — всегда не демо.
 * Инвариант держит constraint в БД, а здесь собраны обе точки, где бэкенд
 * пишет уровень. Автор при публикации уровень не присылает: место в каталоге
 * не выбирают себе сами, его дают модерация или ручной отбор.
 */
export const MARKET_TIER_BEST = 1;
export const MARKET_TIER_MODERATED = 2;
export const MARKET_TIER_DEMO = 3;

/** Уровень новой публикации: демо падает вниз, всё остальное — второй. */
export function tierForNewQuest(isDemo: boolean): number {
    return isDemo ? MARKET_TIER_DEMO : MARKET_TIER_MODERATED;
}

/**
 * Уровень при повторной публикации. Ручной первый уровень не снимается
 * обычной перепубликацией; демо при снятии флага поднимается до второго,
 * а выставленный флаг демо всегда опускает квест на третий.
 */
export const MARKET_TIER_ON_REPUBLISH_SQL =
    'CASE WHEN EXCLUDED.is_demo THEN 3 WHEN quests.market_tier = 3 THEN 2 ELSE quests.market_tier END';

/** Разбирает уровень из query/тела админки: только целые 1..3. */
export function parseMarketTier(raw: unknown): number | null {
    const value = typeof raw === 'string' && raw.trim() !== '' ? Number(raw) : raw;
    if (typeof value !== 'number' || !Number.isInteger(value)) return null;
    if (value < MARKET_TIER_BEST || value > MARKET_TIER_DEMO) return null;
    return value;
}
