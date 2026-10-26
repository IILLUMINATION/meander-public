/**
 * SQL каталога маркета (`GET /quests`).
 *
 * Строка запроса собрана здесь, а не внутри маршрута, потому что на ней
 * держатся три разных обещания экрана: видны только опубликованные квесты,
 * показывается только то, что разрешено adult-настройкой зрителя, и номер
 * плейсхолдера жанра не съезжает, когда поиск уже занял `$1`.
 */

// Стиль ника автора подмешиваем джоином, а не через view: на проде
// `market_quests` определён явным списком колонок, и `CREATE OR REPLACE VIEW`
// с `q.*` переписал бы его состав.
//
// Просмотры живут в `quest_views` по дням, а не в `quests`, поэтому считаем их
// подзапросом: колонка `views_count` нужна и каталогу, и карточке квеста.
// `(quest_id, user_id, day)` — первичный ключ таблицы, так что фильтр по
// `quest_id` идёт по индексу.
export const QUEST_VIEWS_COUNT_SQL =
    "(SELECT COALESCE(SUM(v.views), 0)::int FROM quest_views v WHERE v.quest_id = mq.id)";

const SELECT =
    `SELECT mq.*, ${QUEST_VIEWS_COUNT_SQL} AS views_count, ` +
    "p.cosmetics ->> 'name_style' AS author_name_style, p.cosmetics AS author_cosmetics " +
    "FROM market_quests mq LEFT JOIN profiles p ON p.id = mq.author_id " +
    "WHERE mq.status = 'published'";

export interface MarketListOptions {
    search?: string;
    category?: string;
    showNsfw?: boolean;
    viewerId?: string | null;
}

export interface BuiltQuery {
    text: string;
    params: any[];
}

export function marketListQuery({ search, category, showNsfw = false, viewerId = null }: MarketListOptions): BuiltQuery {
    let text = SELECT;
    const params: any[] = [];

    if (!showNsfw) {
        text += ' AND mq.is_nsfw = FALSE';
    }

    // Ищем и по названию, и по автору: поле в маркете подписано «Найти историю,
    // автора, жанр…», а до этой ветки ник автора не находился вообще — на проде
    // по слову «NN» каталог отвечал пустотой, тогда как в нём восемь
    // опубликованных квестов с таким ником автора. Один плейсхолдер на оба
    // условия, параметр в массиве один — как в поиске музыкального маркета.
    if (search) {
        text += ` AND (mq.title ILIKE $${params.length + 1} OR mq.author_name ILIKE $${params.length + 1})`;
        params.push(`%${search}%`);
    }

    if (category && category !== 'All') {
        text += ` AND $${params.length + 1} = ANY(mq.genres)`;
        params.push(category);
    }

    // Guideline 1.2: заблокированный автор пропадает из каталога у того, кто
    // его заблокировал. Гостю скрывать некого — без зрителя условия нет, и
    // нумерация плейсхолдеров поиска остаётся прежней. Условие идёт последним,
    // чтобы номера поиска и жанра не зависели от входа в аккаунт.
    if (viewerId) {
        text += ` AND NOT EXISTS (
            SELECT 1 FROM user_blocks ub
            WHERE ub.user_id = $${params.length + 1} AND ub.blocked_id = mq.author_id
        )`;
        params.push(viewerId);
    }

    text += ' ORDER BY mq.created_at DESC';

    return { text, params };
}
