-- Несколько поддерживаемых языков у квеста (#331, доработка).
--
-- Автор выбирает языки в настройках квеста, они лежат в `config.json` как
-- `languages` (плюс `language` — первый, для старых потребителей). Сервер
-- хранит список отдельной колонкой, чтобы маркет поднимал «свои» квесты
-- первыми, не распаковывая архивы.
--
-- ВНИМАНИЕ ПРОД: витрина `market_quests` определена явным списком колонок.
-- Postgres разрешает `CREATE OR REPLACE VIEW` только добавлять колонки в
-- КОНЕЦ списка, поэтому `q.languages` идёт последним — после `q.market_tier`.
--
-- ПОРЯДОК ВЫКАТКИ: сначала этот файл, потом бэкенд. Публикация (POST /quests)
-- пишет `languages`, и без колонки загрузка квеста упала бы 500-й. Файл
-- идемпотентен, повторить можно.
--
--   sudo -u postgres psql -d meander_db -v ON_ERROR_STOP=1 \
--     -f backend/migration_quest_languages.sql
--
-- Проверка после применения:
--   SELECT count(*) FILTER (WHERE cardinality(languages) > 0) AS with_langs,
--          count(*) FILTER (WHERE language IS NOT NULL)  AS with_primary
--     FROM quests;

-- 1. Колонка. Пустой массив — «автор не указал»; NULL не используем, чтобы
--    клиенту не приходилось различать две формы «ничего».
ALTER TABLE quests
    ADD COLUMN IF NOT EXISTS languages TEXT[] NOT NULL DEFAULT '{}';

-- 2. Перенос уже указанных языков в список: у старых квестов он из одного
--    элемента. Повторный запуск ничего не портит: пустые списки получают
--    единственный тег заново, непустые не трогаются.
UPDATE quests
   SET languages = ARRAY[language]
 WHERE language IS NOT NULL
   AND cardinality(languages) = 0;

-- 3. Витрина: прежний список колонок плюс `languages` в конце.
CREATE OR REPLACE VIEW market_quests AS
SELECT
    q.id,
    q.download_url,
    q.preview_image_url,
    q.title,
    q.description,
    q.downloads_count,
    q.version,
    q.created_at,
    q.updated_at,
    q.status,
    q.author_id,
    q.moderator_comment,
    q.category,
    q.file_hash,
    q.is_featured,
    q.like_count,
    q.dislike_count,
    q.quest_size_bytes,
    q.node_count,
    q.estimated_playtime,
    q.github_release_id,
    q.genres,
    q.is_demo,
    q.is_nsfw,
    p.full_name AS author_name,
    p.is_verified AS author_is_verified,
    (SELECT AVG(r.rating) FROM ratings r WHERE r.quest_id = q.id) AS average_rating,
    q.language,
    q.market_tier,
    q.languages
FROM quests q
LEFT JOIN profiles p ON q.author_id = p.id;

-- Витрину пересоздал суперюзер — вернём владельца приложению, иначе бэкенд
-- потеряет права на неё при следующей ротации.
ALTER VIEW market_quests OWNER TO meander_user;

-- 4. Откат:
--    ALTER TABLE quests DROP COLUMN IF EXISTS languages;
--    (витрину пересоздать прежним списком, без q.languages)