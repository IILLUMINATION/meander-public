import pool from '../config/database';

// ============================================================================
//  КАТАЛОГ КОСМЕТИКИ ПРОФИЛЯ
//
//  Реестр предметов и их слотов. Это зеркало клиентского каталога
//  (apps/main_app/lib/features/profile/cosmetics/cosmetic_model.dart): id,
//  слот и редкость обязаны совпадать, иначе клиент покажет предмет, который
//  сервер отвергнет при выдаче или экипировке.
//
//  Хранится только то, чем пользователь ВЛАДЕЕТ (user_cosmetics) и что
//  НАДЕТО (profiles.cosmetics). Сами эффекты рисуются на клиенте кодом,
//  поэтому сюда не надо заливать ассеты.
// ============================================================================

export type CosmeticSlot = 'banner' | 'background' | 'avatar_frame' | 'name_style' | 'effect';
export type CosmeticTier = 'common' | 'rare' | 'epic' | 'legendary';

export interface CosmeticDef {
    id: string;
    slot: CosmeticSlot;
    tier: CosmeticTier;
}

const ROWS: ReadonlyArray<readonly [string, CosmeticSlot, CosmeticTier]> = [
    ['beige', 'banner', 'common'],
    ['forest', 'banner', 'common'],
    ['royal_purple', 'banner', 'common'],
    ['sunset', 'banner', 'common'],
    ['ocean', 'banner', 'common'],
    ['rose', 'banner', 'common'],
    ['cyber', 'banner', 'common'],
    ['mono', 'banner', 'common'],
    ['aurora', 'banner', 'common'],
    ['aurora_drift', 'banner', 'rare'],
    ['lava_flow', 'banner', 'rare'],
    ['neon_grid', 'banner', 'epic'],
    ['starfield', 'banner', 'epic'],
    ['oil_slick', 'banner', 'epic'],
    ['gold_leaf', 'banner', 'legendary'],
    ['frost_panel', 'banner', 'rare'],
    ['midnight_surf', 'banner', 'rare'],
    ['vapor_silk', 'banner', 'epic'],
    ['solar_prominence', 'banner', 'epic'],
    ['green_horizon', 'banner', 'legendary'],
    ['rose_quartz', 'banner', 'common'],
    // Арт-баннеры и фоны из одного набора картинок: баннер — полоса в шапке,
    // фон — та же картинка под затемнением на всю страницу профиля.
    ['art_night_meadow', 'banner', 'common'],
    ['art_golden_field', 'banner', 'common'],
    ['art_lone_tree', 'banner', 'common'],
    ['art_forest_bridge', 'banner', 'common'],
    ['art_pond_robot', 'banner', 'common'],
    ['art_open_road', 'banner', 'common'],
    ['bg_night_meadow', 'background', 'common'],
    ['bg_golden_field', 'background', 'common'],
    ['bg_lone_tree', 'background', 'common'],
    ['bg_forest_bridge', 'background', 'common'],
    ['bg_pond_robot', 'background', 'common'],
    ['bg_open_road', 'background', 'common'],
    ['prism_ring', 'avatar_frame', 'rare'],
    ['neon_pulse', 'avatar_frame', 'rare'],
    ['gold_laurel', 'avatar_frame', 'legendary'],
    ['ember_orbit', 'avatar_frame', 'epic'],
    ['glitch_ring', 'avatar_frame', 'epic'],
    ['frost_circle', 'avatar_frame', 'rare'],
    ['soft_line', 'avatar_frame', 'common'],
    ['solar_corona', 'avatar_frame', 'legendary'],
    ['holo_band', 'avatar_frame', 'epic'],
    ['frost_crown', 'avatar_frame', 'rare'],
    ['mint_halo', 'avatar_frame', 'common'],
    ['sunset_glow', 'name_style', 'rare'],
    ['frost_blue', 'name_style', 'rare'],
    ['toxic_lime', 'name_style', 'rare'],
    ['royal_gold', 'name_style', 'legendary'],
    ['magenta_neon', 'name_style', 'epic'],
    ['pride_wave', 'name_style', 'epic'],
    ['ink_violet', 'name_style', 'common'],
    ['polar_shimmer', 'name_style', 'epic'],
    ['copper_name', 'name_style', 'rare'],
    ['pulsar', 'name_style', 'legendary'],
    ['rose_neon', 'name_style', 'rare'],
    ['graphite', 'name_style', 'common'],
    ['snowfall', 'effect', 'rare'],
    ['campfire_embers', 'effect', 'rare'],
    ['stardust', 'effect', 'epic'],
    ['fireflies', 'effect', 'rare'],
    ['coin_rain', 'effect', 'legendary'],
    ['cherry_blossom', 'effect', 'rare'],
    ['hearts', 'effect', 'rare'],
    ['confetti', 'effect', 'common'],
    ['cold_rain', 'effect', 'common'],
    ['blizzard', 'effect', 'epic'],
    ['fireworks', 'effect', 'legendary'],
    ['rose_down', 'effect', 'epic'],
    ['monsoon', 'effect', 'rare'],
    ['witchfire', 'effect', 'rare'],
    ['glitter', 'effect', 'common'],
];

export const COSMETICS: ReadonlyMap<string, CosmeticDef> = new Map(
    ROWS.map(([id, slot, tier]) => [id, { id, slot, tier }] as const),
);

export const COSMETIC_SLOTS: CosmeticSlot[] = ['banner', 'background', 'avatar_frame', 'name_style', 'effect'];

/// Бесплатные предметы не требуют записи в `user_cosmetics`.
export function isFreeCosmetic(id: string): boolean {
    return COSMETICS.get(id)?.tier === 'common';
}

export function cosmeticSlot(id: string): CosmeticSlot | undefined {
    return COSMETICS.get(id)?.slot;
}

export type EquippedMap = Partial<Record<CosmeticSlot, string | null>>;

/**
 * Нормализует `cosmetics` из запроса: { slot: id | null }.
 * Бросает Error с русским сообщением — клиент показывает его в снэкбаре.
 */
export function validateEquipped(value: any): EquippedMap {
    if (value === null || value === undefined) return {};
    if (typeof value !== 'object' || Array.isArray(value)) {
        throw new Error('cosmetics must be an object');
    }
    const result: EquippedMap = {};
    for (const slot of COSMETIC_SLOTS) {
        const raw = value[slot];
        if (raw === undefined) continue;
        if (raw === null || raw === '') {
            result[slot] = null;
            continue;
        }
        if (typeof raw !== 'string') {
            throw new Error(`cosmetics.${slot} must be a string`);
        }
        const def = COSMETICS.get(raw);
        if (!def) throw new Error(`Неизвестное оформление: ${raw}`);
        if (def.slot !== slot) {
            throw new Error(`«${raw}» не подходит в слот «${slot}»`);
        }
        result[slot] = raw;
    }
    return result;
}

/**
 * Предметы, на которые у пользователя нет права (бесплатные не проверяются).
 * Права с истёкшим сроком не учитываются.
 */
export async function findMissingGrants(userId: string, ids: string[]): Promise<string[]> {
    const need = ids.filter((id) => !isFreeCosmetic(id));
    if (need.length === 0) return [];
    const res = await pool.query(
        `SELECT cosmetic_id FROM user_cosmetics
          WHERE user_id = $1
            AND cosmetic_id = ANY($2::text[])
            AND (expires_at IS NULL OR expires_at > NOW())`,
        [userId, need],
    );
    const held = new Set(res.rows.map((r: any) => r.cosmetic_id as string));
    return need.filter((id) => !held.has(id));
}

/** Надетые предметы пользователя с действующими правами. */
export async function equippedFor(userId: string): Promise<EquippedMap> {
    const res = await pool.query('SELECT cosmetics FROM profiles WHERE id = $1', [userId]);
    const raw = res.rows[0]?.cosmetics;
    if (!raw || typeof raw !== 'object') return {};
    return sanitizeStored(raw);
}

/**
 * Читает сохранённый снап: выбрасывает id, которых больше нет в каталоге
 * (каталог может сократиться), и предметы не своего слота.
 */
export function sanitizeStored(raw: any): EquippedMap {
    const result: EquippedMap = {};
    if (!raw || typeof raw !== 'object') return result;
    for (const slot of COSMETIC_SLOTS) {
        const value = (raw as any)[slot];
        if (typeof value !== 'string' || value.length === 0) continue;
        const def = COSMETICS.get(value);
        if (def && def.slot === slot) (result as any)[slot] = value;
    }
    return result;
}

/** Права пользователя: id + срок (null = бессрочно). */
export async function listGrants(userId: string): Promise<Array<{ id: string; expires_at: string | null; tier: CosmeticTier }>> {
    const res = await pool.query(
        `SELECT cosmetic_id, expires_at FROM user_cosmetics
          WHERE user_id = $1
            AND (expires_at IS NULL OR expires_at > NOW())`,
        [userId],
    );
    return res.rows
        .map((r: any) => ({
            id: r.cosmetic_id as string,
            expires_at: r.expires_at ? new Date(r.expires_at).toISOString() : null,
            tier: COSMETICS.get(r.cosmetic_id)?.tier ?? 'common',
        }))
        .filter((r: any) => COSMETICS.has(r.id));
}

/**
 * Выдаёт предметы. Возвращает, сколько добавилось/обновилось.
 * [days] === null — бессрочно; иначе срок отсрочки от max(NOW(), текущий).
 */
export async function grantCosmetics(
    userId: string,
    ids: string[],
    options: { days: number | null; source: string; reason?: string; grantedBy?: string | null },
): Promise<{ granted: string[]; skipped: string[] }> {
    const granted: string[] = [];
    const skipped: string[] = [];
    for (const id of ids) {
        const def = COSMETICS.get(id);
        if (!def) {
            skipped.push(id);
            continue;
        }
        if (isFreeCosmetic(id)) {
            // Бесплатное и так доступно — заводить строку права бессмысленно.
            skipped.push(id);
            continue;
        }
        await pool.query(
            `INSERT INTO user_cosmetics (user_id, cosmetic_id, slot, tier, source, reason, granted_by, expires_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7,
                     CASE WHEN $8::int IS NULL THEN NULL ELSE GREATEST(NOW(), COALESCE(
                         (SELECT expires_at FROM user_cosmetics WHERE user_id = $1 AND cosmetic_id = $2),
                         NOW()
                     )) + ($8 || ' days')::INTERVAL END)
             ON CONFLICT (user_id, cosmetic_id) DO UPDATE
               SET source = EXCLUDED.source,
                   reason = COALESCE(EXCLUDED.reason, user_cosmetics.reason),
                   granted_by = EXCLUDED.granted_by,
                   expires_at = CASE
                       WHEN $8::int IS NULL THEN NULL
                       ELSE GREATEST(NOW(), COALESCE(user_cosmetics.expires_at, NOW())) + ($8 || ' days')::INTERVAL
                   END`,
            [
                userId,
                id,
                def.slot,
                def.tier,
                options.source,
                options.reason ?? null,
                options.grantedBy ?? null,
                options.days,
            ],
        );
        granted.push(id);
    }
    return { granted, skipped };
}

/**
 * legacy-синхронизация: `banner_style` читают старые версии приложения.
 * Обновляем только если надетый баннер — статичный пресет из прошлого.
 */
export function legacyBannerStyle(equipped: EquippedMap): { type: 'preset'; id: string } | null {
    const id = equipped.banner;
    if (!id) return null;
    // Все «статичные» id — это те, что были в ALLOWED_BANNER_IDS до косметики.
    return LEGACY_BANNER_IDS.has(id) ? { type: 'preset', id } : null;
}

/**
 * Снимает оформление, срок права на которое истёк.
 *
 * Ношеное хранится одним снапом в `profiles.cosmetics`, а его же читают чужие
 * экраны (ник автора в списке квестов берётся из `cosmetics ->> 'name_style'`),
 * поэтому «предмет кончился» нельзя обработать только при экипировке: иначе
 * новогодний снег продолжал бы идти весь январь.
 *
 * Бесплатные предметы носим всегда; null-значения слотов не трогаем.
 */
export async function sweepExpiredCosmetics(): Promise<number> {
    const free = Array.from(COSMETICS.values())
        .filter((d) => d.tier === 'common')
        .map((d) => d.id);
    const res = await pool.query(
        `WITH worn AS (
             SELECT p.id AS user_id, p.cosmetics
               FROM profiles p
              WHERE p.cosmetics IS NOT NULL
         ),
         kept AS (
             SELECT w.user_id,
                    jsonb_object_agg(e.key, e.value) AS cosmetics
               FROM worn w
               JOIN jsonb_each_text(w.cosmetics) AS e ON TRUE
              WHERE e.value IS NULL
                 OR e.value = ANY($1::text[])
                 OR EXISTS (SELECT 1 FROM user_cosmetics uc
                             WHERE uc.user_id = w.user_id
                               AND uc.cosmetic_id = e.value
                               AND (uc.expires_at IS NULL OR uc.expires_at > NOW()))
           GROUP BY w.user_id
         )
         UPDATE profiles p
            SET cosmetics = k.cosmetics
           FROM kept k
          WHERE p.id = k.user_id
            AND p.cosmetics IS DISTINCT FROM k.cosmetics
         RETURNING p.id`,
        [free],
    );
    return res.rowCount ?? 0;
}

/** Периодический снимок просроченного оформления. Первый запуск — сразу. */
export const startCosmeticExpirySweep = (intervalMs: number = 10 * 60 * 1000) => {
    const run = async () => {
        try {
            const cleared = await sweepExpiredCosmetics();
            if (cleared > 0) {
                console.log(`🎨 Косметика с истёкшим сроком снята у ${cleared} профилей`);
            }
        } catch (e) {
            console.error('Error in cosmetic expiry sweep:', e);
        }
    };
    console.log(`🎨 Cosmetic expiry sweep started (every ${intervalMs / 60000} min)`);
    void run();
    setInterval(run, intervalMs);
};

export const LEGACY_BANNER_IDS = new Set([
    'beige', 'forest', 'royal_purple', 'sunset', 'ocean', 'rose', 'cyber', 'mono', 'aurora',
]);
