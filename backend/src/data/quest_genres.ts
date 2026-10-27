/**
 * Канонические жанры квестов.
 *
 * В базе и в API хранится только id — стабильный латинский ключ. Подписи
 * живут на клиенте, поэтому перевод или переименование жанра не ломает
 * фильтры. Старые записи содержат английские названия (`Fantasy`, `Sci-Fi`),
 * их приводят к id функции ниже; на проде эти значения вычищает
 * `migration_quest_genres.sql`.
 */
export const QUEST_GENRE_IDS = [
  'fantasy', 'dark_fantasy', 'fairytale', 'mythology',
  'sci_fi', 'cyberpunk', 'steampunk', 'post_apocalypse', 'space_opera',
  'horror', 'supernatural', 'vampire', 'werewolf', 'zombie',
  'mystery', 'detective', 'noir', 'crime', 'mafia', 'heist', 'spy',
  'thriller', 'psychological',
  'adventure', 'survival', 'disaster', 'war', 'western', 'pirates',
  'time_travel', 'alternate_history', 'historical',
  'romance', 'drama', 'tragedy', 'comedy', 'satire', 'parody',
  'slice_of_life', 'school', 'family', 'sports', 'music', 'travel',
  'philosophy', 'puzzle', 'escape_room', 'martial_arts', 'medical',
  'political', 'business', 'farming',
] as const;

export type QuestGenreId = (typeof QUEST_GENRE_IDS)[number];

const KNOWN_GENRES = new Set<string>(QUEST_GENRE_IDS);

/** Максимум жанров у квеста — столько же, сколько даёт выбрать редактор. */
export const MAX_QUEST_GENRES = 3;

const LEGACY_ALIASES: Record<string, string> = {
  fantasy: 'fantasy',
  'sci-fi': 'sci_fi',
  scifi: 'sci_fi',
  'science-fiction': 'sci_fi',
  horror: 'horror',
  adventure: 'adventure',
  mystery: 'mystery',
  romance: 'romance',
  comedy: 'comedy',
  thriller: 'thriller',
  historical: 'historical',
  history: 'historical',
  drama: 'drama',
};

/** Приводит значение из старого клиента/базы к каноническому id. */
export function normalizeGenreId(raw: unknown): string | null {
  if (raw === null || raw === undefined) return null;
  const value = String(raw).trim();
  if (!value) return null;
  const key = value.toLowerCase().replace(/[\s_]+/g, '-');
  const alias = LEGACY_ALIASES[key];
  if (alias) return alias;
  const snake = key.replace(/-/g, '_');
  return KNOWN_GENRES.has(snake) ? snake : null;
}

/**
 * Чистит список жанров: выбрасывает неизвестные и повторы, сохраняет порядок
 * и ограничивает длину. Пустой результат означает «автор ничего не выбрал».
 */
export function normalizeQuestGenres(raw: unknown, max = MAX_QUEST_GENRES): string[] {
  const source = Array.isArray(raw) ? raw : [raw];
  const result: string[] = [];
  for (const item of source) {
    const id = normalizeGenreId(item);
    if (!id || result.includes(id)) continue;
    result.push(id);
    if (result.length >= max) break;
  }
  return result;
}
