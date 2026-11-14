/**
 * Язык квеста (#331).
 *
 * Сервер хранит язык отдельной колонкой только ради порядка в маркете:
 * квесты на языке игрока поднимаются над остальными. Отсюда и требования к
 * значению — его не показывают как текст, он сравнивается с кодом языка
 * клиента, поэтому важна форма, а не «правильность» тега.
 */

// Первичный подтег (2–3 буквы) и необязательный регион/скрипт через дефис:
// `ru`, `en`, `zh-CN`, `pt-BR`. Списком языков не проверяем — клиент умеет
// импортировать свой словарь с любым кодом, и сервер не должен его за это
// наказывать молчанием.
const LANGUAGE_TAG = /^[a-z]{2,3}(-[a-z0-9]{2,4})?$/i;

// 35 символов — потолок BCP-47 для одного тега; больше — это уже не язык.
const MAX_LENGTH = 35;

/**
 * Приводит поле `language` из multipart-запроса к значению для колонки:
 * валидная метка либо `null` («автор не указал»). `null` — не ошибка
 * публикации, а обычное состояние: исторически все квесты без метки.
 */
export function normalizeQuestLanguage(raw: unknown): string | null {
    if (typeof raw !== 'string') return null;
    const value = raw.trim();
    if (value.length === 0 || value.length > MAX_LENGTH) return null;
    return LANGUAGE_TAG.test(value) ? value : null;
}

/** Сколько языков квест может заявить одновременно. */
export const MAX_QUEST_LANGUAGES = 8;

/**
 * Приводит `languages` публикации к списку валидных меток.
 *
 * Квест может поддерживать несколько языков (переводы внутри одного архива),
 * поэтому авторы шлют список. Форма приходит из FormData JSON-строкой —
 * так же, как жанры; принимаем и настоящий массив, и строку через запятую.
 * Невалидные метки выбрасываются молча (публикацию за них не отбиваем),
 * дубликаты схлопываются, порядок автора сохраняется: первый тег — основной,
 * по нему старый клиент и `quests.language` считают квест «своим».
 */
export function normalizeQuestLanguages(raw: unknown): string[] {
    const items = Array.isArray(raw) ? raw : parseLanguageList(raw);
    const result: string[] = [];
    // Метки языков регистронезависимы (`ru` и `RU` — один язык), а показываем
    // тот вариант, что прислал автор: сортировка маркета сравнивает префиксы.
    const seen = new Set<string>();
    for (const item of items) {
        const tag = normalizeQuestLanguage(item);
        if (tag && !seen.has(tag.toLowerCase())) {
            seen.add(tag.toLowerCase());
            result.push(tag);
        }
        if (result.length >= MAX_QUEST_LANGUAGES) break;
    }
    return result;
}

function parseLanguageList(raw: unknown): unknown[] {
    if (typeof raw !== 'string') return [];
    const value = raw.trim();
    if (value.length === 0) return [];
    if (value.startsWith('[')) {
        try {
            const parsed = JSON.parse(value);
            return Array.isArray(parsed) ? parsed : [];
        } catch {
            return [];
        }
    }
    return value.split(',');
}
