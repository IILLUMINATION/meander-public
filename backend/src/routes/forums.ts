import { Router, Response } from 'express';
import { validate as uuidValidate } from 'uuid';
import pool from '../config/database';
import authMiddleware, { optionalAuthMiddleware, AuthRequest } from '../middleware/auth';
import {
    FORUM_RULES,
    Tenure,
    canCreateForum,
    getForumsCreatedByDay,
    getKarmaAndLimits,
    getTenure,
    isStaff,
} from '../services/gating';
import { createNotification } from '../services/notifications';
import { moderateWallPost } from '../services/moderation';

const router = Router();

/**
 * Форум — это полка для уже существующих постов сообщества, а не второй вид
 * контента: комментарии, ответы на них, лайки, картинки, жалобы и модерация
 * достались форуму бесплатно, ровно как и право человека удалять свой пост.
 * Поэтому здесь только то, чего у постов не было: участники, бан в рамках
 * форума, заголовок топика и право модерировать.
 */

const AUTHOR_FIELDS = `a.id, a.full_name, a.avatar_url, a.cosmetics, a.role, a.is_verified`;

const SLUG_TRANSLIT: Record<string, string> = {
    а: 'a', б: 'v', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'yo', ж: 'zh', з: 'z', и: 'i',
    й: 'y', к: 'k', л: 'l', м: 'm', н: 'n', о: 'o', п: 'p', р: 'r', с: 's', т: 't',
    у: 'u', ф: 'f', х: 'h', ц: 'c', ч: 'ch', ш: 'sh', щ: 'sch', ъ: '', ы: 'y', ь: '',
    э: 'e', ю: 'yu', я: 'ya',
};

/**
 * Слаг — адрес, и человек придумывает его по-русски. Транслитерация здесь для
 * того, чтобы «Гоблины» превращались в читаемое gobliny, а не в нечитаемый
 * процент-кодед URL.
 */
const slugify = (name: string): string => {
    const latin = name
        .toLowerCase()
        .split('')
        .map(ch => (SLUG_TRANSLIT[ch] !== undefined ? SLUG_TRANSLIT[ch] : ch))
        .join('')
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .slice(0, 32);
    return latin.length >= 3 ? latin : '';
};

const bad = (res: Response, status: number, error: string) => res.status(status).json({ error });

const clampInt = (raw: unknown, fallback: number, max: number): number => {
    const n = parseInt(String(raw), 10);
    if (!Number.isFinite(n) || n <= 0) return fallback;
    return Math.min(n, max);
};

/** Собираем участника форума: роль в форуме, бан, есть ли право модерировать. */
const getAccess = async (forumId: string, userId: string) => {
    const res = await pool.query(
        `SELECT f.creator_id, f.is_restricted, f.kind, f.slug,
                m.role AS member_role, m.joined_at, b.created_at AS banned_at
           FROM forums f
           LEFT JOIN forum_members m ON m.forum_id = f.id AND m.user_id = $2
           LEFT JOIN forum_bans b ON b.forum_id = f.id AND b.user_id = $2
          WHERE f.id = $1`,
        [forumId, userId]
    );
    const row = res.rows[0];
    if (!row) return null;
    return {
        creatorId: row.creator_id as string,
        isRestricted: !!row.is_restricted,
        kind: row.kind as string,
        slug: row.slug as string,
        memberRole: (row.member_role || null) as string | null,
        joined: !!row.joined_at,
        banned: !!row.banned_at,
    };
};

type Access = NonNullable<Awaited<ReturnType<typeof getAccess>>>;

const isForumMod = (access: Access, tenure: Tenure, userId: string): boolean =>
    isStaff(tenure) || access.creatorId === userId || access.memberRole === 'mod';

// =======================================================================
//  КАТАЛОГ
// =======================================================================
// scope=all|mine|quest, sort=active|popular|new. Активность — последний
// живой топик, а не дата создания: каталог, отсортированный по созданиям,
// показывает кладбище.
router.get('/', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    const viewer = req.user?.id || null;
    const scope = (req.query.scope as string) || 'all';
    const sort = (req.query.sort as string) || 'active';
    const search = typeof req.query.q === 'string' && req.query.q.trim() ? `%${req.query.q.trim().toLowerCase()}%` : null;
    const limit = clampInt(req.query.limit, 30, 100);
    const offset = clampInt(req.query.offset, 0, 100000);

    if (scope === 'mine' && !viewer) return bad(res, 401, 'Нужно войти в аккаунт');

    try {
        const result = await pool.query(
            `SELECT f.id, f.slug, f.name, f.description, f.kind, f.quest_id, f.is_restricted,
                    f.created_at,
                    (SELECT COUNT(*)::int FROM forum_members m WHERE m.forum_id = f.id) AS member_count,
                    (SELECT COUNT(*)::int FROM author_posts ap
                      WHERE ap.forum_id = f.id AND ap.is_active = true) AS topics_count,
                    (SELECT MAX(ap2.created_at) FROM author_posts ap2
                      WHERE ap2.forum_id = f.id AND ap2.is_active = true) AS last_activity_at,
                    c.id AS creator_id, c.full_name AS creator_name, c.avatar_url AS creator_avatar_url,
                    c.cosmetics AS creator_cosmetics, c.role AS creator_role,
                    (EXISTS (SELECT 1 FROM forum_members j
                              WHERE j.forum_id = f.id AND j.user_id = $1::uuid)) AS joined
               FROM forums f
               JOIN profiles c ON c.id = f.creator_id
              WHERE f.is_active = true
                AND ($2::text IS NULL OR lower(f.name) LIKE $2 OR lower(f.slug) LIKE $2)
                AND ($3 <> 'mine' OR EXISTS (SELECT 1 FROM forum_members j2
                              WHERE j2.forum_id = f.id AND j2.user_id = $1::uuid))
              ORDER BY ${sort === 'popular'
                ? 'member_count DESC, topics_count DESC'
                : sort === 'new'
                    ? 'f.created_at DESC'
                    : 'last_activity_at DESC NULLS LAST, member_count DESC'}
              LIMIT $4 OFFSET $5`,
            [viewer, search, scope, limit, offset]
        );
        res.json({ forums: result.rows });
    } catch (err) {
        console.error('forums catalog:', err);
        res.status(500).json({ error: 'Не удалось загрузить сообщества' });
    }
});

// =======================================================================
//  ОБСУЖДЕНИЕ КВЕСТА
// =======================================================================
// Форум квеста заводится по первому запросу, а не при публикации: из
// сотен квестов обсуждают единицы, а пустой форум у каждого квеста — это
// мусор в каталоге и лишняя работа миграции на существующие квесты.
router.get('/quest/:questId', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    const { questId } = req.params;
    if (!uuidValidate(questId)) return bad(res, 400, 'Некорректный квест');

    try {
        const quest = await pool.query(
            `SELECT id, title, description, status, author_id FROM quests WHERE id = $1`,
            [questId]
        );
        if (quest.rows.length === 0) return bad(res, 404, 'Квест не найден');
        if (quest.rows[0].status !== 'published') return bad(res, 403, 'Обсуждение открывается после публикации');

        const existing = await pool.query(
            `SELECT id, slug FROM forums WHERE quest_id = $1`,
            [questId]
        );
        if (existing.rows.length > 0) {
            return res.json({ forum_id: existing.rows[0].id, slug: existing.rows[0].slug });
        }

        // Форум квеста принадлежит его автору: он главный по теме, и порог
        // активности на его собственное обсуждение не распространяется.
        const created = await pool.query(
            `INSERT INTO forums (slug, name, description, kind, quest_id, creator_id)
             VALUES ($1, $2, $3, 'quest', $4, $5)
             ON CONFLICT (quest_id) DO UPDATE SET quest_id = EXCLUDED.quest_id
             RETURNING id, slug`,
            [
                `quest-${questId.slice(0, 8)}`,
                `Обсуждение: ${String(quest.rows[0].title).slice(0, FORUM_RULES.maxNameChars)}`,
                quest.rows[0].description ? String(quest.rows[0].description).slice(0, FORUM_RULES.maxDescriptionChars) : null,
                questId,
                quest.rows[0].author_id,
            ]
        );
        const forum = created.rows[0];
        await pool.query(
            `INSERT INTO forum_members (forum_id, user_id, role) VALUES ($1, $2, 'mod')
             ON CONFLICT (forum_id, user_id) DO NOTHING`,
            [forum.id, quest.rows[0].author_id]
        );

        res.json({ forum_id: forum.id, slug: forum.slug });
    } catch (err) {
        console.error('quest forum:', err);
        res.status(500).json({ error: 'Не удалось открыть обсуждение' });
    }
});

// =======================================================================
//  ГОРЯЧИЕ ОБСУЖДЕНИЯ СРАЗУ ПО ВСЕМ СООБЩЕСТВАМ
// =======================================================================
// Нужны ленте сообщества: у неё своя пагинация по постам, а топик — это тот
// же пост, только с `forum_id`, и без адреса полки карточка не может увести
// человека в сообщество. Поэтому строка отдаётся вместе со слагом и именем.
// Порядок — не по свежести: в окно попадают две недели, а за интерес считают
// и лайки, и ответы, потому что обсуждение без ответов не обсуждение.
router.get('/topics/hot', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    const viewer = req.user?.id || null;
    const limit = clampInt(req.query.limit, 12, 25);

    try {
        const result = await pool.query(
            `SELECT ap.id, ap.title, ap.content, ap.created_at,
                    ap.likes_count, ap.media_urls, ap.tags,
                    co.comment_count AS comments_count,
                    f.slug AS forum_slug, f.name AS forum_name, f.kind AS forum_kind,
                    a.id AS author_id, a.full_name AS author_name, a.avatar_url AS author_avatar_url,
                    a.cosmetics AS author_cosmetics, a.role AS author_role, a.is_verified AS author_is_verified,
                    (EXISTS (SELECT 1 FROM author_post_likes l
                              WHERE l.post_id = ap.id AND l.user_id = $1::uuid)) AS is_liked_by_viewer
               FROM author_posts ap
               JOIN profiles a ON a.id = ap.author_id
               JOIN forums f ON f.id = ap.forum_id
               CROSS JOIN LATERAL (
                   SELECT COUNT(*)::int AS comment_count
                     FROM author_post_comments c
                    WHERE c.post_id = ap.id AND c.is_active = true
               ) co
              WHERE ap.is_active = true AND f.is_active = true
                AND ap.created_at > now() - INTERVAL '14 days'
              ORDER BY (ap.likes_count + co.comment_count * 2) DESC, ap.created_at DESC
              LIMIT $2`,
            [viewer, limit]
        );
        res.json({ topics: result.rows });
    } catch (err) {
        console.error('hot topics:', err);
        res.status(500).json({ error: 'Не удалось загрузить обсуждения' });
    }
});

// =======================================================================
//  СОЗДАНИЕ
// =======================================================================
router.post('/', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const name = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
    const description = typeof req.body?.description === 'string' ? req.body.description.trim() : '';
    const requestedSlug = typeof req.body?.slug === 'string' ? req.body.slug.trim().toLowerCase() : '';

    if (!name || name.length < 3) return bad(res, 400, 'Название короче 3 символов');
    if (name.length > FORUM_RULES.maxNameChars) {
        return bad(res, 400, `Название длиннее ${FORUM_RULES.maxNameChars} символов`);
    }
    if (description.length > FORUM_RULES.maxDescriptionChars) {
        return bad(res, 400, `Описание длиннее ${FORUM_RULES.maxDescriptionChars} символов`);
    }

    try {
        const tenure = await getTenure(me);
        if (!tenure) return bad(res, 401, 'Профиль не найден');
        if (!canCreateForum(tenure)) {
            return bad(res, 403,
                `Сообщество может создать тот, кто с нами ${FORUM_RULES.minAccountAgeDaysToCreate} дней `
                + 'или уже публиковал квест.');
        }
        if (!isStaff(tenure) && await getForumsCreatedByDay(me) >= FORUM_RULES.maxCreatedByDay) {
            return bad(res, 429, `За сутки можно создать ${FORUM_RULES.maxCreatedByDay} сообщества.`);
        }

        const base = (requestedSlug && /^[a-z0-9][a-z0-9_-]{2,39}$/.test(requestedSlug)
            ? requestedSlug
            : slugify(name)) || `forum-${me.slice(0, 8)}`;

        const taken = await pool.query(`SELECT 1 FROM forums WHERE slug = $1`, [base]);
        // Слоты в адресе не освобождаются сами: если «goblins» занят, человек
        // получает понятную просьбу, а не тихо переименованный форум.
        if (taken.rows.length > 0) {
            return bad(res, 409, `Сообщество с адресом ${base} уже есть. Придумай другой.`);
        }

        const created = await pool.query(
            `INSERT INTO forums (slug, name, description, kind, creator_id, is_restricted)
             VALUES ($1, $2, $3, 'user', $4, $5)
             ON CONFLICT (slug) DO NOTHING
             RETURNING id, slug, name, description, kind, is_restricted, created_at`,
            [base, name, description || null, me, !!req.body?.is_restricted]
        );
        if (created.rows.length === 0) {
            return bad(res, 409, `Сообщество с адресом ${base} уже есть. Придумай другой.`);
        }
        const forum = created.rows[0];
        await pool.query(
            `INSERT INTO forum_members (forum_id, user_id, role) VALUES ($1, $2, 'mod')
             ON CONFLICT (forum_id, user_id) DO NOTHING`,
            [forum.id, me]
        );

        res.status(201).json(forum);
    } catch (err) {
        console.error('forum create:', err);
        res.status(500).json({ error: 'Не удалось создать сообщество' });
    }
});

// =======================================================================
//  ЛОББИ
// =======================================================================
const findForum = async (slug: string) => {
    const res = await pool.query(
        `SELECT f.id, f.slug, f.name, f.description, f.kind, f.quest_id, f.is_restricted,
                f.creator_id, f.created_at, q.title AS quest_title,
                (SELECT COUNT(*)::int FROM forum_members m WHERE m.forum_id = f.id) AS member_count,
                (SELECT COUNT(*)::int FROM author_posts ap
                  WHERE ap.forum_id = f.id AND ap.is_active = true) AS topics_count
           FROM forums f
           LEFT JOIN quests q ON q.id = f.quest_id
          WHERE f.slug = $1 AND f.is_active = true`,
        [slug]
    );
    return res.rows[0] || null;
};

router.get('/:slug', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    const viewer = req.user?.id || null;
    try {
        const forum = await findForum(req.params.slug);
        if (!forum) return bad(res, 404, 'Сообщество не найдено');

        const [mods, access] = await Promise.all([
            pool.query(
                `SELECT ${AUTHOR_FIELDS}, m.role AS forum_role, m.joined_at
                   FROM forum_members m JOIN profiles a ON a.id = m.user_id
                  WHERE m.forum_id = $1 AND m.role = 'mod'
                  ORDER BY m.joined_at ASC
                  LIMIT 20`,
                [forum.id]
            ),
            viewer ? getAccess(forum.id, viewer) : null,
        ]);

        res.json({
            forum: { ...forum, joined: !!access?.joined, banned: access?.banned ?? false },
            mods: mods.rows,
        });
    } catch (err) {
        console.error('forum lobby:', err);
        res.status(500).json({ error: 'Не удалось загрузить сообщество' });
    }
});

// Правила и название правит сам создатель (и модераторы форума, и админ).
router.patch('/:slug', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const slug = req.params.slug;
    try {
        const forum = await findForum(slug);
        if (!forum) return bad(res, 404, 'Сообщество не найдено');

        const tenure = await getTenure(me);
        if (!tenure) return bad(res, 401, 'Профиль не найден');
        const access = await getAccess(forum.id, me);
        if (!access || !isForumMod(access, tenure, me)) {
            return bad(res, 403, 'Настройки форума меняет его создатель, модератор форума или админ');
        }

        const name = typeof req.body?.name === 'string' ? req.body.name.trim() : null;
        const description = typeof req.body?.description === 'string' ? req.body.description.trim() : null;
        if (name !== null && (name.length < 3 || name.length > FORUM_RULES.maxNameChars)) {
            return bad(res, 400, `Название должно быть от 3 до ${FORUM_RULES.maxNameChars} символов`);
        }
        if (description !== null && description.length > FORUM_RULES.maxDescriptionChars) {
            return bad(res, 400, `Описание длиннее ${FORUM_RULES.maxDescriptionChars} символов`);
        }

        const updated = await pool.query(
            `UPDATE forums SET
                name = COALESCE($2, name),
                description = COALESCE($3, description),
                is_restricted = COALESCE($4, is_restricted)
              WHERE id = $1
              RETURNING id, slug, name, description, is_restricted`,
            [forum.id, name, description, typeof req.body?.is_restricted === 'boolean' ? req.body.is_restricted : null]
        );
        res.json(updated.rows[0]);
    } catch (err) {
        console.error('forum patch:', err);
        res.status(500).json({ error: 'Не удалось сохранить изменения' });
    }
});

// =======================================================================
//  УЧАСТИЕ
// =======================================================================
router.post('/:slug/join', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    try {
        const forum = await findForum(req.params.slug);
        if (!forum) return bad(res, 404, 'Сообщество не найдено');
        const access = await getAccess(forum.id, me);
        if (access?.banned) return bad(res, 403, 'Вас ограничили в этом сообществе');

        await pool.query(
            `INSERT INTO forum_members (forum_id, user_id) VALUES ($1, $2)
             ON CONFLICT (forum_id, user_id) DO NOTHING`,
            [forum.id, me]
        );
        res.json({ success: true, member_count: forum.member_count + 1 });
    } catch (err) {
        console.error('forum join:', err);
        res.status(500).json({ error: 'Не удалось вступить' });
    }
});

router.delete('/:slug/join', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    try {
        const forum = await findForum(req.params.slug);
        if (!forum) return bad(res, 404, 'Сообщество не найдено');
        // Создатель не может выйти из своего форума: иначе сообщество остаётся
        // без того, кто в нём решает. Админу можно — у него есть другие рычаги.
        if (forum.creator_id === me) {
            const tenure = await getTenure(me);
            if (!tenure || !isStaff(tenure)) {
                return bad(res, 400, 'Создатель может только передать форум модератору');
            }
        }
        await pool.query(`DELETE FROM forum_members WHERE forum_id = $1 AND user_id = $2`, [forum.id, me]);
        res.json({ success: true });
    } catch (err) {
        console.error('forum leave:', err);
        res.status(500).json({ error: 'Не удалось выйти' });
    }
});

// =======================================================================
//  МОДЕРАЦИЯ ФОРУМА
// =======================================================================
const requireMod = async (req: AuthRequest, res: Response): Promise<{ forum: any; access: Access; tenure: any } | null> => {
    try {
        const forum = await findForum(req.params.slug);
        if (!forum) {
            bad(res, 404, 'Сообщество не найдено');
            return null;
        }
        const me = req.user!.id;
        const tenure = await getTenure(me);
        if (!tenure) {
            bad(res, 401, 'Профиль не найден');
            return null;
        }
        const access = await getAccess(forum.id, me);
        if (!access || !isForumMod(access, tenure, me)) {
            bad(res, 403, 'Это право только у создателя форума, его модератора или админа');
            return null;
        }
        return { forum, access, tenure };
    } catch (err) {
        // null здесь уже значит «ответ отправлен, стой»: сбой базы не должен
        // оставлять запрос без ответа — клиент будет ждать до своего таймаута.
        console.error('forum moderation gate:', err);
        bad(res, 500, 'Не удалось проверить права');
        return null;
    }
};

router.post('/:slug/ban/:userId', authMiddleware, async (req: AuthRequest, res: Response) => {
    const target = req.params.userId;
    if (!uuidValidate(target)) return bad(res, 400, 'Некорректный идентификатор');
    const gate = await requireMod(req, res);
    if (!gate) return;
    if (gate.tenure.role !== 'admin' && target === gate.forum.creator_id) {
        return bad(res, 403, 'Создателя форума забанить нельзя');
    }

    try {
        await pool.query(
            `INSERT INTO forum_bans (forum_id, user_id, banned_by, reason)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (forum_id, user_id) DO UPDATE SET reason = EXCLUDED.reason, banned_by = EXCLUDED.banned_by`,
            [gate.forum.id, target, req.user!.id, typeof req.body?.reason === 'string' ? req.body.reason.slice(0, 300) : null]
        );
        // Заодно снимаем участие: «забанен, но состоит» — состояние, в котором
        // потом никто не разберётся.
        await pool.query(`DELETE FROM forum_members WHERE forum_id = $1 AND user_id = $2`, [gate.forum.id, target]);
        await createNotification({
            userId: target,
            actorId: req.user!.id,
            type: 'forum_ban',
            payload: { forum: gate.forum.name, forum_slug: gate.forum.slug, reason: req.body?.reason || null },
        });
        res.json({ success: true });
    } catch (err) {
        console.error('forum ban:', err);
        res.status(500).json({ error: 'Не удалось ограничить' });
    }
});

router.delete('/:slug/ban/:userId', authMiddleware, async (req: AuthRequest, res: Response) => {
    const target = req.params.userId;
    if (!uuidValidate(target)) return bad(res, 400, 'Некорректный идентификатор');
    const gate = await requireMod(req, res);
    if (!gate) return;
    try {
        await pool.query(`DELETE FROM forum_bans WHERE forum_id = $1 AND user_id = $2`, [gate.forum.id, target]);
        res.json({ success: true });
    } catch (err) {
        console.error('forum unban:', err);
        res.status(500).json({ error: 'Не удалось снять ограничение' });
    }
});

// Модератору нужно видеть, кого он ограничил: без этого списка «забанить»
// из клиента стало бы действием, которое можно отменить только через базу.
router.get('/:slug/bans', authMiddleware, async (req: AuthRequest, res: Response) => {
    const gate = await requireMod(req, res);
    if (!gate) return;
    try {
        const result = await pool.query(
            `SELECT ${AUTHOR_FIELDS}, b.reason, b.created_at AS banned_at
               FROM forum_bans b JOIN profiles a ON a.id = b.user_id
              WHERE b.forum_id = $1
              ORDER BY b.created_at DESC
              LIMIT 50`,
            [gate.forum.id]
        );
        res.json({ bans: result.rows });
    } catch (err) {
        console.error('forum bans:', err);
        res.status(500).json({ error: 'Не удалось загрузить ограничения' });
    }
});

// Модератора назначает создатель (или админ) — это единственный способ
// передать форум, не удаляя его.
router.post('/:slug/moderators/:userId', authMiddleware, async (req: AuthRequest, res: Response) => {
    const target = req.params.userId;
    if (!uuidValidate(target)) return bad(res, 400, 'Некорректный идентификатор');
    try {
        const forum = await findForum(req.params.slug);
        if (!forum) return bad(res, 404, 'Сообщество не найдено');
        const me = req.user!.id;
        if (forum.creator_id !== me) {
            const tenure = await getTenure(me);
            if (!tenure || !isStaff(tenure)) return bad(res, 403, 'Модератора назначает только создатель форума');
        }

        await pool.query(
            `INSERT INTO forum_members (forum_id, user_id, role) VALUES ($1, $2, 'mod')
             ON CONFLICT (forum_id, user_id) DO UPDATE SET role = 'mod'`,
            [forum.id, target]
        );
        res.json({ success: true });
    } catch (err) {
        console.error('forum mod assign:', err);
        res.status(500).json({ error: 'Не удалось назначить модератора' });
    }
});

router.post('/:slug/report', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const reason = typeof req.body?.reason === 'string' ? req.body.reason.trim() : '';
    if (!reason) return bad(res, 400, 'Опишите, что не так');
    try {
        const forum = await findForum(req.params.slug);
        if (!forum) return bad(res, 404, 'Сообщество не найдено');
        const duplicate = await pool.query(
            `SELECT 1 FROM reports
              WHERE reporter_id = $1 AND reported_type = 'forum' AND reported_id = $2 AND status = 'pending'`,
            [me, forum.id]
        );
        if (duplicate.rows.length > 0) return res.json({ success: true, already: true });
        await pool.query(
            `INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status)
             VALUES ($1, 'forum', $2, $3, $4, 'pending')`,
            [me, forum.id, 'USER_REPORT', reason.slice(0, 500)]
        );
        res.json({ success: true });
    } catch (err) {
        console.error('forum report:', err);
        res.status(500).json({ error: 'Не удалось отправить жалобу' });
    }
});

// =======================================================================
//  ТОПИКИ
// =======================================================================
const SORTS: Record<string, string> = {
    new: 'ap.created_at DESC',
    top: 'ap.likes_count DESC, ap.created_at DESC',
    // Без префикса ap.: упорядочиваем по алиасу из SELECT (живой счётчик
    // комментариев), а не по колонке author_posts.comments_count — её не
    // обновляет ни один код, на проде она расходилась с реальностью
    // примерно на половине постов.
    discussed: 'comments_count DESC, ap.created_at DESC',
};

router.get('/:slug/posts', optionalAuthMiddleware, async (req: AuthRequest, res: Response) => {
    const viewer = req.user?.id || null;
    const sort = SORTS[(req.query.sort as string) || 'new'] ? SORTS[(req.query.sort as string) || 'new'] : SORTS.new;
    const limit = clampInt(req.query.limit, 25, 50);
    const offset = clampInt(req.query.offset, 0, 100000);

    try {
        const forum = await findForum(req.params.slug);
        if (!forum) return bad(res, 404, 'Сообщество не найдено');

        const result = await pool.query(
            `SELECT ap.id, ap.title, ap.content, ap.created_at, ap.updated_at, ap.forum_id,
                    ap.likes_count, ap.media_urls, ap.tags, ap.interest_score,
                    (SELECT COUNT(*)::int FROM author_post_comments c
                      WHERE c.post_id = ap.id AND c.is_active = true) AS comments_count,
                    a.id AS author_id, a.full_name AS author_name, a.avatar_url AS author_avatar_url,
                    a.cosmetics AS author_cosmetics, a.role AS author_role, a.is_verified AS author_is_verified,
                    (EXISTS (SELECT 1 FROM author_post_likes l
                              WHERE l.post_id = ap.id AND l.user_id = $1::uuid)) AS is_liked_by_viewer
               FROM author_posts ap
               JOIN profiles a ON a.id = ap.author_id
              WHERE ap.forum_id = $2 AND ap.is_active = true
                AND NOT EXISTS (
                  SELECT 1 FROM user_blocks ub
                  WHERE ub.user_id = $1::uuid AND ub.blocked_id = ap.author_id
                )
              ORDER BY ${sort}
              LIMIT $3 OFFSET $4`,
            [viewer, forum.id, limit, offset]
        );
        res.json({ forum_id: forum.id, slug: forum.slug, topics: result.rows });
    } catch (err) {
        console.error('forum topics:', err);
        res.status(500).json({ error: 'Не удалось загрузить обсуждения' });
    }
});

router.post('/:slug/posts', authMiddleware, async (req: AuthRequest, res: Response) => {
    const me = req.user!.id;
    const title = typeof req.body?.title === 'string' ? req.body.title.trim() : '';
    const content = typeof req.body?.content === 'string' ? req.body.content.trim() : '';
    const mediaUrls = Array.isArray(req.body?.media_urls) ? req.body.media_urls.slice(0, 6) : [];

    if (!title) return bad(res, 400, 'У обсуждения должен быть заголовок');
    if (title.length > FORUM_RULES.maxTitleChars) {
        return bad(res, 400, `Заголовок длиннее ${FORUM_RULES.maxTitleChars} символов`);
    }
    if (!content) return bad(res, 400, 'Пустой топик');
    if (content.length > FORUM_RULES.maxBodyChars) {
        return bad(res, 400, `Сообщение длиннее ${FORUM_RULES.maxBodyChars} символов`);
    }

    try {
        const forum = await findForum(req.params.slug);
        if (!forum) return bad(res, 404, 'Сообщество не найдено');

        const tenure = await getTenure(me);
        if (!tenure) return bad(res, 401, 'Профиль не найден');
        const access = await getAccess(forum.id, me);
        if (!access) return bad(res, 404, 'Сообщество не найдено');
        if (access.banned) return bad(res, 403, 'Вас ограничили в этом сообществе');
        if (access.isRestricted && !access.joined && !isForumMod(access, tenure, me)) {
            return bad(res, 403, 'В этом сообществе пишут только участники — вступите, чтобы задать вопрос');
        }

        // Кулдаун считаем по всем постам человека, а не по одному форуму:
        // обходить его пересадкой топика на другую полку — ровно то, чего
        // лимит и не должен допускать.
        const limits = await getKarmaAndLimits(me);
        if (limits.postCooldownMin > 0) {
            const recent = await pool.query(
                `SELECT 1 FROM author_posts
                  WHERE author_id = $1 AND created_at > NOW() - ($2 || ' minutes')::INTERVAL
                  LIMIT 1`,
                [me, String(limits.postCooldownMin)]
            );
            if (recent.rows.length > 0) {
                return bad(res, 429, `Следующее обсуждение можно через ${limits.postCooldownMin} мин.`);
            }
        }

        const tags = Array.from(new Set(
            (content.match(/#[a-zA-Zа-яА-ЯёЁ0-9_]+/g) || []).map((t: string) => t.toLowerCase().substring(1))
        ));

        const inserted = await pool.query(
            `INSERT INTO author_posts (author_id, content, media_urls, tags, forum_id, title)
             VALUES ($1, $2, $3, $4, $5, $6)
             RETURNING id, author_id, title, content, created_at, likes_count, forum_id`,
            [me, content, JSON.stringify(mediaUrls), tags, forum.id, title]
        );
        const post = inserted.rows[0];

        await pool.query(
            `INSERT INTO forum_members (forum_id, user_id) VALUES ($1, $2)
             ON CONFLICT (forum_id, user_id) DO NOTHING`,
            [forum.id, me]
        );

        res.status(201).json(post);

        // Фон-проверка та же, что у постов стены: топик опубликован сразу,
        // правила отклоняют только явную запрещёнку, спорное уходит на разбор
        // человеку. Оставить форумные топики единственным контентом без
        // присмотра — значит предложить спамеру самый чистый вход.
        const markdownImages = Array.from(content.matchAll(/!\[.*?\]\((https?:\/\/.*?)\)/g)).map((m: any) => m[1]);
        moderateWallPost(content, Array.from(new Set([...mediaUrls.map(String), ...markdownImages])))
            .then(async mod => {
                if (mod.needsReview) {
                    await pool.query(
                        `INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status)
                         VALUES ($1, 'wall_post', $2, 'AUTO_FLAGGED_FOR_REVIEW', $3, 'pending')`,
                        [me, post.id, `Топик форума ${forum.slug} помечен на ручной разбор: ${mod.reason}`]
                    );
                } else if (!mod.approved) {
                    await pool.query(`UPDATE author_posts SET is_active = false WHERE id = $1`, [post.id]);
                } else {
                    await pool.query(`UPDATE author_posts SET interest_score = $1 WHERE id = $2`, [mod.interest_score, post.id]);
                }
            })
            .catch(err => console.error('forum topic moderation:', err));
    } catch (err) {
        console.error('forum topic create:', err);
        res.status(500).json({ error: 'Не удалось опубликовать обсуждение' });
    }
});

// Удаление топика модератором форума — то же мягкое удаление, что и у автора
// с постом, плюс запись в журнал жалоб, чтобы решение можно было пересмотреть.
router.post('/:slug/posts/:postId/remove', authMiddleware, async (req: AuthRequest, res: Response) => {
    const { postId } = req.params;
    if (!uuidValidate(postId)) return bad(res, 400, 'Некорректный идентификатор');
    const gate = await requireMod(req, res);
    if (!gate) return;

    try {
        const removed = await pool.query(
            `UPDATE author_posts SET is_active = false
              WHERE id = $1 AND forum_id = $2 AND is_active = true
              RETURNING id, author_id`,
            [postId, gate.forum.id]
        );
        if (removed.rows.length === 0) return bad(res, 404, 'Топик уже удалён или не из этого сообщества');
        await pool.query(
            `INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status)
             VALUES ($1, 'wall_post', $2, 'MODERATOR_REMOVED', $3, 'resolved')`,
            [req.user!.id, postId, `Удалён модератором форума ${gate.forum.slug}: ${String(req.body?.reason || 'без причины').slice(0, 300)}`]
        );
        await createNotification({
            userId: removed.rows[0].author_id,
            actorId: req.user!.id,
            type: 'forum_topic_removed',
            payload: {
                forum: gate.forum.name,
                forum_slug: gate.forum.slug,
                title: req.body?.topic_title ? String(req.body.topic_title).slice(0, 200) : null,
            },
        });
        res.json({ success: true });
    } catch (err) {
        console.error('forum topic remove:', err);
        res.status(500).json({ error: 'Не удалось удалить топик' });
    }
});

export default router;
