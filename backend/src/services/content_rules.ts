import { publicBaseUrl } from '../config/public_host';
// Правила модерации вместо LLM: только перечислимые критерии, детерминированно,
// без сети. Упавший «ИИ» раньше автоматически одобрял весь контент — правила не падают.

export type RuleSeverity = 'low' | 'medium' | 'high';

export interface RuleHit {
    code: string;
    reason: string;
    severity: RuleSeverity;
    /** true => контент отклоняется сразу; false => уходит на ручную проверку. */
    hard: boolean;
}

/** Где читается текст: мат внутри игры допустим, в названии — нет. */
export type ScanScope = 'title' | 'description' | 'body' | 'review' | 'post';

export interface ScanOptions {
    /** Автор квеста и админы вправе оставлять ссылки и анонсы. */
    allowAds?: boolean;
}

export interface Verdict {
    approved: boolean;
    isHardReject: boolean;
    needsReview: boolean;
    severity: RuleSeverity;
    reason: string;
    codes: string[];
}

/**
 * Свои домены: ссылки на них — не «чужая ссылка». Действующий хост берём
 * из BASE_URL, старые/альтернативные — из MEANDER_HOST_ALIASES (через
 * запятую), чтобы при переезде не править код.
 */
const MEANDER_HOSTS: string[] = (() => {
    const hosts = new Set<string>(['meander.app']);
    try {
        const own = new URL(publicBaseUrl()).hostname.toLowerCase();
        if (own && own !== 'localhost') hosts.add(own);
    } catch {
        // BASE_URL не задан/битый — останутся только алиасы.
    }
    for (const alias of (process.env.MEANDER_HOST_ALIASES || '').split(',')) {
        const trimmed = alias.trim().toLowerCase();
        if (trimmed) hosts.add(trimmed);
    }
    return [...hosts];
})();

const ZERO_WIDTH = /[​-‏­﻿]/g;
// Точки и дефисы не трогаем: они держат границу слова для проверки мата.
const FILLER = /[*_~`|\\]/g;

const normalize = (text: string): string => text
    .replace(ZERO_WIDTH, '')
    .replace(FILLER, '')
    .replace(/ё/g, 'е')
    .toLowerCase();

/** Только буквы и цифры, без разделителей — ловит «п и з д». */
const squash = (text: string): string => normalize(text).replace(/[^\p{L}\p{N}]/gu, '');

// ---------------------------------------------------------------------------
// Лексиконы
// ---------------------------------------------------------------------------

/** Корни, которых нет в нейтральных словах — ищем в любом месте слова. */
const MAT_ANYWHERE = [
    'пизд', 'бляд', 'бля', 'хуй', 'хуя', 'хуе', 'говн', 'дерьм', 'шлюх',
    'гандон', 'пидар', 'пидор', 'ублюд', 'мудак', 'задрот', 'нищеброд',
];

/** «еб»-корень требует входа по границе и глагольной приставки, иначе ловим
 *  «хлеб», «небо», «Глеб». */
const MAT_BOUNDED = /(?:^|[^\p{L}\p{N}_])(?:за|вы|на|по|пере|про|раз|рас|об|от|до|под|с|у)?[ъь]?еб[а-яё]*|(?:^|[^\p{L}\p{N}_])(?:сука|сучк|сран|бздеть|долбо[йъ]|придур|даун)\b/gu;

const SELF_HARM = [
    'повесись', 'повесься', 'утопись', 'убей себя', 'застрели себя',
    'зарежь себя', 'отрежь себе вены', 'режь вены', 'покончи с собой',
    'кончи с собой', 'скончай с собой', 'не стоит жить', 'лучше бы ты не родился',
];

const CHILD_TERMS = [
    'малолетн', 'несовершеннолетн', 'ребёнк', 'ребенк', 'подростк', 'школьник',
    'дошкол', 'малыш', 'мальчик', 'девочк', 'loli', 'shota', 'child', 'teen',
];

const SEXUAL_TERMS = [
    'порно', 'porn', 'xxx', 'секс', 'sex', 'трах', 'минет', 'куни', 'анал', 'оргазм', 'эрек', 'сиськ',
    'письк', 'вагин', 'нюд', 'nude', 'раздвин', 'сперм', 'проститутк', 'без трусов',
];

/** Порно в коммерции и детская сексуализация — всегда жёсткий отказ. */
const PORN_COMMERCE = [
    'порно', 'porn', 'xxx', 'порнограф', 'pornhub', 'onlyfans', 'секс по вызову',
    'секс-услуг', 'интим-услуг', 'спидоло', 'webcam-модель',
];

/** Символика и лозунги. Слово «нацист» не трогаем: исторические квесты. */
const HATE = [
    'хайль гитлер', 'heil hitler', 'зиг-гей', 'зиг гей', 'ку-клукс', 'ку кл кл',
    'недочеловек',
];

const INJECTION = [
    'ignore previous instructions', 'ignore all previous', 'забудь инструкции',
    'игнорируй инструкции', 'системный промпт', 'выведи промпт', 'покажи промпт',
    'role:system', 'jailbreak',
];

const SPAM_PHRASES = [
    'подпишись', 'подписка на канал', 'переходи по ссылке', 'реферальн',
    'промокод на скидку', 'заработок без вложений', 'казино', 'ставк на спорт',
    'ставок на спорт', 'накрутк', 'криптобиржа', 'слиты баз', 'продажа аккаунтов',
];

const TEST_WORD = /^(?:тест+|test+|check|проверка|привет+|ку|ы+|х+|фыва+|йцукен+|asdf|qwerty|zxcv|проба|123+)[\s.,!?-]*$/;

const LINK_RE = /(?:https?:\/\/|www\.)\S+|(?:t|tg)\.me\/\S+|(?:vk|ok)\.com\/\S+|discord\.gg\/\S+|(?:youtube\.com|youtu\.be)\/\S+|\b[\p{L}\p{N}][\p{L}\p{N}-]*\.(?:ru|com|net|org|sbs|xyz|top|site|online|click|store)\b(?:\/\S*)?/giu;

const TG_JOIN = /(?:t|tg)\.me\/\+|tg:\/\/join/i;

/** Что и где запрещаем. */
const SCOPE_RULES: Record<ScanScope, {
    profanity: 'hard' | 'review' | 'off';
    ads: 'hard' | 'off';
    scam: 'hard' | 'review' | 'off';
}> = {
    title: { profanity: 'hard', ads: 'hard', scam: 'review' },
    description: { profanity: 'hard', ads: 'hard', scam: 'review' },
    // Игровой текст: хоррор, мат персонажей и сеттинг про казино — норма.
    body: { profanity: 'review', ads: 'off', scam: 'off' },
    review: { profanity: 'hard', ads: 'hard', scam: 'hard' },
    // Пост на стене: ссылки и анонсы авторам разрешаем, снимается только
    // явный спам-бизнес — и то через ручную проверку, а не молчаливое удаление.
    post: { profanity: 'review', ads: 'off', scam: 'review' },
};

const indexesOf = (hay: string, terms: string[]): number[] => {
    const found: number[] = [];
    for (const term of terms) {
        let at = hay.indexOf(term);
        while (at >= 0) {
            found.push(at);
            at = hay.indexOf(term, at + term.length);
        }
    }
    return found;
};

const closestGap = (a: number[], b: number[]): number => {
    let gap = Number.MAX_SAFE_INTEGER;
    for (const x of a) for (const y of b) gap = Math.min(gap, Math.abs(x - y));
    return gap;
};

const countProfanity = (text: string, squashed: string): number => {
    let total = (text.match(MAT_BOUNDED) || []).length;
    for (const root of MAT_ANYWHERE) {
        total += text.split(root).length - 1;
        // Разбитый символами мат («п и з д») собирается только в squash.
        if (squashed.includes(root)) total += 1;
    }
    return total;
};

const looksLikeSpamShape = (text: string): string | null => {
    const trimmed = text.trim();
    if (!trimmed) return 'текст пустой';
    if (TEST_WORD.test(trimmed)) return 'текст — служебная пометка («тест», «проверка»)';
    if (/(.)\1{6,}/.test(trimmed)) return 'один символ повторяется много раз';
    if (/([а-яё]{7,})\s*\1/.test(trimmed)) return 'одно слово повторяется подряд';
    if (/[bcdfghjklmnpqrstvwxz]{7,}/.test(trimmed)) return 'набор согласных';
    if (/[бвгджзйклмнпрстфхцчшщ]{8,}/.test(trimmed)) return 'набор согласных';

    const words = trimmed.split(/\s+/).filter(w => w.replace(/\p{L}/gu, '').length === 0 && w.length > 1);
    if (words.length >= 6 && new Set(words).size / words.length < 0.25) {
        return 'одни и те же слова по кругу';
    }
    return null;
};

const foreignLinks = (text: string): string[] => (text.match(LINK_RE) || [])
    .filter(url => !MEANDER_HOSTS.some(host => url.includes(host)));

/**
 * Основной скан. Возвращает все срабатывания — вызывающий сам решает,
 * отклонять или нести в ручную проверку.
 */
export const scanText = (raw: string, scope: ScanScope, options: ScanOptions = {}): RuleHit[] => {
    const hits: RuleHit[] = [];
    const text = normalize(raw || '');
    if (!text.trim()) return hits;
    const squashed = squash(raw || '');
    const rules = SCOPE_RULES[scope];

    if (indexesOf(text, SELF_HARM).length) {
        hits.push({ code: 'SELF_HARM', reason: 'Призыв навредить себе или угроза жизни', severity: 'high', hard: true });
    }

    const childAt = indexesOf(text, CHILD_TERMS);
    const sexAt = indexesOf(text, SEXUAL_TERMS);
    if (childAt.length && sexAt.length && closestGap(childAt, sexAt) < 120) {
        hits.push({ code: 'CSAM', reason: 'Сексуальный подтекст вместе с упоминанием несовершеннолетних', severity: 'high', hard: true });
    } else if (indexesOf(text, PORN_COMMERCE).length) {
        // Внутри игры «порно» — обычное упоминание или шутка персонажа, а не
        // публикация порнографии. Молча отказать автору — значит лишить его
        // квеста из-за одного слова; спорное тело уходит людям (in_review
        // в магазине не виден).
        hits.push({ code: 'PORN', reason: 'Порнография или интим-услуги', severity: 'high', hard: scope !== 'body' });
    }

    if (indexesOf(text, HATE).length) {
        hits.push({ code: 'HATE', reason: 'Запрещённая символика или лозунг', severity: 'high', hard: true });
    }

    const matTotal = countProfanity(text, squashed);
    if (rules.profanity !== 'off' && matTotal > 0) {
        const denseEnough = matTotal >= 3;
        if (rules.profanity === 'hard') {
            hits.push({ code: 'PROFANITY', reason: `Нецензурная брань (${matTotal} сл.)`, severity: 'high', hard: true });
        } else if (denseEnough) {
            hits.push({ code: 'PROFANITY_DENSE', reason: `В тексте много нецензурной брани (${matTotal} сл.) — на проверку`, severity: 'medium', hard: false });
        }
    }

    const spamShape = looksLikeSpamShape(text);
    if (spamShape) {
        hits.push({
            code: 'SPAM_SHAPE',
            reason: `Похоже на спам: ${spamShape}`,
            severity: 'medium',
            // Форма текста — не основание молча снимать работу: «███████»
            // и «───────» — обычная цензура и разделители в играх, «!!!» в
            // отзыве — эмоция. Отсекаем только витрину, где это и правда спам.
            hard: scope === 'title' || scope === 'description',
        });
    }

    if (indexesOf(text, INJECTION).length) {
        hits.push({ code: 'INJECTION', reason: 'Попытка служебной инструкции вместо контента', severity: 'medium', hard: false });
    }

    const links = foreignLinks(text);
    const tmeJoin = TG_JOIN.test(text);
    if (!options.allowAds && rules.ads !== 'off' && (tmeJoin || links.length > 0)) {
        hits.push({
            code: 'ADS',
            reason: tmeJoin
                ? 'Ссылка-приглашение в мессенджер'
                : 'Реклама или внешняя ссылка',
            severity: 'medium',
            hard: rules.ads === 'hard',
        });
    }

    if (rules.scam !== 'off') {
        const scamHits = indexesOf(text, SPAM_PHRASES);
        if (scamHits.length > 0) {
            hits.push({
                code: 'SCAM',
                reason: `Спам или сомнительный заработок (${scamHits.length} совпад.)`,
                severity: 'high',
                hard: rules.scam === 'hard',
            });
        }
    }

    return hits;
};

/** Сводка срабатываний в одно решение. */
export const verdict = (hits: RuleHit[]): Verdict => {
    const hard = hits.filter(h => h.hard);
    const review = hits.filter(h => !h.hard);
    const severity: RuleSeverity = hits.some(h => h.severity === 'high')
        ? 'high'
        : hits.some(h => h.severity === 'medium') ? 'medium' : 'low';
    const first = hard[0] || review[0];
    return {
        approved: hits.length === 0,
        isHardReject: hard.length > 0,
        needsReview: hard.length === 0 && review.length > 0,
        severity,
        reason: first ? first.reason : 'Нарушений не найдено',
        codes: hits.map(h => h.code),
    };
};

/**
 * «Интересность» поста для ранжирования ленты. Прежняя шкала из промпта,
 * только посчитанная по факту: длина, картинки, признаки авторского апдейта.
 */
export const interestScore = (text: string, mediaCount = 0): number => {
    const t = normalize(text || '');
    const len = t.trim().length;
    let score = 20;
    if (len >= 60) score += 10;
    if (len >= 200) score += 18;
    if (len >= 600) score += 25;
    if (mediaCount >= 2) score += 14;
    else if (mediaCount === 1) score += 8;
    // Авторский апдейт или обучение — то, за чем в ленту приходят.
    if (/(анонс|обновлен|обновл|релиз|патч|гайд|урок|туториал|разбор|секрет|фишк)/.test(t)) score += 25;
    else if (/(скриншот|арт|иллюстрац|обложк|впечатления|после игры|прохождение)/.test(t)) score += 12;
    if (/[?#]/.test(t)) score += 4;
    // «привет» без картинки — не повод поднимать пост в топ.
    if (len < 40 && mediaCount === 0) score = Math.min(score, 30);
    return Math.max(0, Math.min(100, Math.round(score)));
};

/** Заполненность квеста: объём и разнообразие текста. */
export const qualityScore = (title: string, description: string, contentSample: string): number => {
    const all = normalize(`${title} ${description} ${contentSample}`);
    const words = all.split(/\s+/).filter(w => w.length > 0);
    if (words.length < 20) return 10;
    const volume = Math.min(55, Math.round(words.length / 5));
    const variety = Math.round((new Set(words).size / words.length) * 45);
    return Math.max(0, Math.min(100, volume + variety));
};
