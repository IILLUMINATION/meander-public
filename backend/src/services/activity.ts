import pool from '../config/database';

/**
 * Активность пользователей для админ-дашборда.
 *
 * Визиты копятся в `user_activity_daily`: `touchDailyActivity` зовётся из
 * auth-middleware на каждый авторизованный запрос, но увеличивает счётчик не
 * чаще раза в 30 минут на человека — визит это сессия, а не запрос.
 *
 * Остальные цифры дашборд берёт из уже существующих таблиц действий
 * (`quest_votes`, `dm_messages`, `quests`, ...). Отдельного лога событий нет
 * намеренно: он дублировал бы данные, за которыми и так следит приложение.
 */

const VISIT_THROTTLE_MS = 30 * 60 * 1000;
const lastVisitAt = new Map<string, number>();

export function touchDailyActivity(userId?: string) {
    if (!userId) return;
    const now = Date.now();
    if (now - (lastVisitAt.get(userId) ?? 0) < VISIT_THROTTLE_MS) return;
    lastVisitAt.set(userId, now);
    pool
        .query(
            `INSERT INTO user_activity_daily (user_id, day, visits, last_seen_at)
             VALUES ($1, CURRENT_DATE, 1, now())
             ON CONFLICT (user_id, day) DO UPDATE
                SET visits = user_activity_daily.visits + 1,
                    last_seen_at = now()`,
            [userId],
        )
        .catch(() => {
            // best-effort: на старых базах таблицы ещё может не быть
        });
}

export interface ActivityDay {
    day: string;
    visits: number;
    active_users: number;
    new_users: number;
    actions: number;
}

export interface ActivityOverview {
    days: number;
    summary: Record<string, number>;
    actions: Record<string, number>;
    series: ActivityDay[];
    top_users: Record<string, unknown>[];
}

const clampDays = (raw: unknown): number => {
    const value = Number(raw);
    if (!Number.isFinite(value)) return 30;
    return Math.min(365, Math.max(1, Math.trunc(value)));
};

async function loadSummary(days: number) {
    const result = await pool.query(
        `SELECT
            (SELECT COUNT(*) FROM profiles)::int AS total_users,
            (SELECT COUNT(*) FROM profiles
              WHERE created_at >= date_trunc('day', now()))::int AS new_today,
            (SELECT COUNT(*) FROM profiles
              WHERE created_at >= now() - make_interval(days => 7))::int AS new_7d,
            (SELECT COUNT(*) FROM profiles
              WHERE created_at >= now() - make_interval(days => $1::int))::int AS new_period,
            (SELECT COUNT(*) FROM profiles
              WHERE last_seen_at >= now() - interval '5 minutes')::int AS online_now,
            (SELECT COUNT(*) FROM profiles
              WHERE last_seen_at >= date_trunc('day', now()))::int AS active_today,
            (SELECT COUNT(*) FROM profiles
              WHERE last_seen_at >= now() - make_interval(days => 7))::int AS active_7d,
            (SELECT COUNT(*) FROM profiles
              WHERE last_seen_at >= now() - make_interval(days => $1::int))::int AS active_period,
            (SELECT COUNT(*) FROM profiles
              WHERE created_at >= now() - make_interval(days => $1::int)
                AND last_seen_at >= now() - interval '7 days')::int AS new_active_7d,
            (SELECT COALESCE(SUM(visits), 0) FROM user_activity_daily
              WHERE day = CURRENT_DATE)::int AS visits_today,
            (SELECT COALESCE(SUM(visits), 0) FROM user_activity_daily
              WHERE day >= CURRENT_DATE - 6)::int AS visits_7d,
            (SELECT COALESCE(SUM(visits), 0) FROM user_activity_daily
              WHERE day >= CURRENT_DATE - ($1::int - 1))::int AS visits_period,
            (SELECT COUNT(*) FROM user_activity_daily
              WHERE day = CURRENT_DATE)::int AS visited_today`,
        [days],
    );
    return result.rows[0] ?? {};
}

async function loadActions(days: number) {
    const result = await pool.query(
        `SELECT
            (SELECT COUNT(*) FROM quest_votes
              WHERE created_at >= now() - make_interval(days => $1::int))::int AS quest_votes,
            (SELECT COUNT(*) FROM music_votes
              WHERE created_at >= now() - make_interval(days => $1::int))::int AS music_votes,
            (SELECT COUNT(*) FROM asset_votes
              WHERE created_at >= now() - make_interval(days => $1::int))::int AS asset_votes,
            (SELECT COUNT(*) FROM ratings
              WHERE created_at >= now() - make_interval(days => $1::int))::int AS ratings,
            (SELECT COUNT(*) FROM reviews
              WHERE created_at >= now() - make_interval(days => $1::int))::int AS reviews,
            (SELECT COUNT(*) FROM music_reviews
              WHERE created_at >= now() - make_interval(days => $1::int))::int AS music_reviews,
            (SELECT COUNT(*) FROM asset_reviews
              WHERE created_at >= now() - make_interval(days => $1::int))::int AS asset_reviews,
            (SELECT COUNT(*) FROM dm_messages
              WHERE created_at >= now() - make_interval(days => $1::int)
                AND deleted_at IS NULL)::int AS messages,
            (SELECT COUNT(*) FROM quests
              WHERE created_at >= now() - make_interval(days => $1::int))::int AS quests_created,
            (SELECT COUNT(*) FROM quests
              WHERE created_at >= now() - make_interval(days => $1::int)
                AND status = 'published')::int AS quests_published,
            (SELECT COUNT(*) FROM author_posts
              WHERE created_at >= now() - make_interval(days => $1::int)
                AND is_active)::int AS posts_created,
            (SELECT COUNT(*) FROM quest_downloads
              WHERE downloaded_at >= now() - make_interval(days => $1::int))::int AS downloads,
            (SELECT COALESCE(SUM(views), 0) FROM quest_views
              WHERE day >= CURRENT_DATE - ($1::int - 1))::int AS quest_views,
            (SELECT COALESCE(SUM(seconds), 0) FROM playtime_daily
              WHERE day >= CURRENT_DATE - ($1::int - 1))::int AS playtime_seconds`,
        [days],
    );
    return result.rows[0] ?? {};
}

async function loadSeries(days: number) {
    const result = await pool.query(
        `WITH days AS (
            SELECT generate_series(
                CURRENT_DATE - ($1::int - 1),
                CURRENT_DATE,
                interval '1 day'
            )::date AS day
        ),
        visits AS (
            SELECT day,
                   SUM(visits)::int AS visits,
                   COUNT(*)::int AS active_users
              FROM user_activity_daily
             WHERE day >= CURRENT_DATE - ($1::int - 1)
             GROUP BY day
        ),
        newcomers AS (
            SELECT created_at::date AS day, COUNT(*)::int AS new_users
              FROM profiles
             WHERE created_at >= CURRENT_DATE - ($1::int - 1)
             GROUP BY 1
        ),
        events AS (
            SELECT day, COUNT(*)::int AS actions
              FROM (
                SELECT created_at::date AS day FROM quest_votes
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT created_at::date FROM music_votes
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT created_at::date FROM asset_votes
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT created_at::date FROM ratings
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT created_at::date FROM reviews
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT created_at::date FROM music_reviews
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT created_at::date FROM asset_reviews
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT created_at::date FROM dm_messages
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                   AND deleted_at IS NULL
                UNION ALL SELECT created_at::date FROM quests
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT created_at::date FROM author_posts
                 WHERE created_at >= CURRENT_DATE - ($1::int - 1)
                   AND is_active
                UNION ALL SELECT downloaded_at::date FROM quest_downloads
                 WHERE downloaded_at >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT day FROM quest_views
                 WHERE day >= CURRENT_DATE - ($1::int - 1)
                UNION ALL SELECT day FROM playtime_daily
                 WHERE day >= CURRENT_DATE - ($1::int - 1)
              ) raw
             GROUP BY day
        )
        SELECT to_char(d.day, 'YYYY-MM-DD') AS day,
               COALESCE(v.visits, 0) AS visits,
               COALESCE(v.active_users, 0) AS active_users,
               COALESCE(n.new_users, 0) AS new_users,
               COALESCE(e.actions, 0) AS actions
          FROM days d
          LEFT JOIN visits v ON v.day = d.day
          LEFT JOIN newcomers n ON n.day = d.day
          LEFT JOIN events e ON e.day = d.day
         ORDER BY d.day`,
        [days],
    );
    return result.rows as ActivityDay[];
}

async function loadTopUsers(days: number) {
    const result = await pool.query(
        `WITH events AS (
            SELECT user_id FROM quest_votes
             WHERE created_at >= now() - make_interval(days => $1::int)
            UNION ALL SELECT user_id FROM music_votes
             WHERE created_at >= now() - make_interval(days => $1::int)
            UNION ALL SELECT user_id FROM asset_votes
             WHERE created_at >= now() - make_interval(days => $1::int)
            UNION ALL SELECT author_id FROM reviews
             WHERE created_at >= now() - make_interval(days => $1::int)
            UNION ALL SELECT author_id FROM music_reviews
             WHERE created_at >= now() - make_interval(days => $1::int)
            UNION ALL SELECT author_id FROM asset_reviews
             WHERE created_at >= now() - make_interval(days => $1::int)
            UNION ALL SELECT sender_id FROM dm_messages
             WHERE created_at >= now() - make_interval(days => $1::int)
               AND deleted_at IS NULL
            UNION ALL SELECT author_id FROM quests
             WHERE created_at >= now() - make_interval(days => $1::int)
            UNION ALL SELECT author_id FROM author_posts
             WHERE created_at >= now() - make_interval(days => $1::int)
               AND is_active
        ),
        visits AS (
            SELECT user_id, SUM(visits)::int AS visits
              FROM user_activity_daily
             WHERE day >= CURRENT_DATE - ($1::int - 1)
             GROUP BY user_id
        ),
        people AS (
            SELECT user_id FROM events
            UNION
            SELECT user_id FROM visits
        ),
        reactions AS (
            SELECT user_id, COUNT(*)::int AS n
              FROM (
                SELECT user_id FROM quest_votes
                 WHERE created_at >= now() - make_interval(days => $1::int)
                UNION ALL SELECT user_id FROM music_votes
                 WHERE created_at >= now() - make_interval(days => $1::int)
                UNION ALL SELECT user_id FROM asset_votes
                 WHERE created_at >= now() - make_interval(days => $1::int)
              ) raw
             GROUP BY user_id
        ),
        messages AS (
            SELECT sender_id AS user_id, COUNT(*)::int AS n
              FROM dm_messages
             WHERE created_at >= now() - make_interval(days => $1::int)
               AND deleted_at IS NULL
             GROUP BY sender_id
        ),
        quests_made AS (
            SELECT author_id AS user_id, COUNT(*)::int AS n
              FROM quests
             WHERE created_at >= now() - make_interval(days => $1::int)
             GROUP BY author_id
        ),
        posts_made AS (
            SELECT author_id AS user_id, COUNT(*)::int AS n
              FROM author_posts
             WHERE created_at >= now() - make_interval(days => $1::int)
               AND is_active
             GROUP BY author_id
        )
        SELECT pr.id,
               pr.full_name,
               pr.avatar_url,
               pr.last_seen_at,
               COALESCE(v.visits, 0)::int AS visits,
               COALESCE(r.n, 0)::int AS reactions,
               COALESCE(m.n, 0)::int AS messages,
               COALESCE(q.n, 0)::int AS quests,
               COALESCE(po.n, 0)::int AS posts,
               (COALESCE(v.visits, 0) + COALESCE(r.n, 0) + COALESCE(m.n, 0)
                 + COALESCE(q.n, 0) * 3 + COALESCE(po.n, 0) * 2)::int AS score
          FROM people u
          JOIN profiles pr ON pr.id = u.user_id
          LEFT JOIN visits v ON v.user_id = u.user_id
          LEFT JOIN reactions r ON r.user_id = u.user_id
          LEFT JOIN messages m ON m.user_id = u.user_id
          LEFT JOIN quests_made q ON q.user_id = u.user_id
          LEFT JOIN posts_made po ON po.user_id = u.user_id
         ORDER BY score DESC, pr.last_seen_at DESC NULLS LAST
         LIMIT 25`,
        [days],
    );
    return result.rows as Record<string, unknown>[];
}

export async function getActivityOverview(rawDays: unknown): Promise<ActivityOverview> {
    const days = clampDays(rawDays);
    const [summary, actions, series, topUsers] = await Promise.all([
        loadSummary(days),
        loadActions(days),
        loadSeries(days),
        loadTopUsers(days),
    ]);
    return { days, summary, actions, series, top_users: topUsers };
}
