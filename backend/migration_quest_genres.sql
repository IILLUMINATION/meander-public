-- Жанры: перевод старых английских названий в канонические id.
--
-- До этой миграции в quests.genres лежали подписи ("Fantasy", "Sci-Fi", …),
-- а фильтр маркета сравнивал строку целиком. После перехода на id подписи
-- строит клиент, поэтому старые значения нужно один раз переписать: иначе
-- квест с "Fantasy" не найдётся фильтром "fantasy".
--
-- Запуск (на проде — только вместе с деплоем бэкенда):
--   sudo -u postgres psql -d meander_db -v ON_ERROR_STOP=1 -f migration_quest_genres.sql
--
-- Откат: содержимое quests_genres_backup_20261027 (id, genres, category).

BEGIN;

-- Копия до правки: миграция меняет данные, а не только схему.
CREATE TABLE IF NOT EXISTS quests_genres_backup_20261027 AS
SELECT id, genres, category FROM quests;

WITH normalized AS (
  SELECT
    id,
    ARRAY(
      SELECT DISTINCT CASE g
        WHEN 'Fantasy'    THEN 'fantasy'
        WHEN 'Sci-Fi'     THEN 'sci_fi'
        WHEN 'SciFi'      THEN 'sci_fi'
        WHEN 'Horror'     THEN 'horror'
        WHEN 'Adventure'  THEN 'adventure'
        WHEN 'Mystery'    THEN 'mystery'
        WHEN 'Romance'    THEN 'romance'
        WHEN 'Comedy'     THEN 'comedy'
        WHEN 'Thriller'   THEN 'thriller'
        WHEN 'Historical' THEN 'historical'
        WHEN 'History'    THEN 'historical'
        WHEN 'Drama'      THEN 'drama'
        -- Уже канонические id и незнакомые значения не трогаем.
        ELSE g
      END
      FROM unnest(COALESCE(genres, '{}'::text[])) AS g
    ) AS new_genres
  FROM quests
)
UPDATE quests q
SET genres = n.new_genres,
    category = CASE
      WHEN cardinality(n.new_genres) > 0 THEN n.new_genres[1]
      ELSE q.category
    END
FROM normalized n
WHERE q.id = n.id
  AND (
    q.genres IS DISTINCT FROM n.new_genres
    OR (cardinality(n.new_genres) > 0 AND q.category IS DISTINCT FROM n.new_genres[1])
  );

-- Квесты, у которых жанры не дошли, но категория есть (старое приложение
-- присылало только category).
UPDATE quests q
SET genres = ARRAY[CASE q.category
        WHEN 'Fantasy'    THEN 'fantasy'
        WHEN 'Sci-Fi'     THEN 'sci_fi'
        WHEN 'SciFi'      THEN 'sci_fi'
        WHEN 'Horror'     THEN 'horror'
        WHEN 'Adventure'  THEN 'adventure'
        WHEN 'Mystery'    THEN 'mystery'
        WHEN 'Romance'    THEN 'romance'
        WHEN 'Comedy'     THEN 'comedy'
        WHEN 'Thriller'   THEN 'thriller'
        WHEN 'Historical' THEN 'historical'
        WHEN 'History'    THEN 'historical'
        WHEN 'Drama'      THEN 'drama'
        ELSE q.category
      END],
    category = CASE q.category
        WHEN 'Fantasy'    THEN 'fantasy'
        WHEN 'Sci-Fi'     THEN 'sci_fi'
        WHEN 'SciFi'      THEN 'sci_fi'
        WHEN 'Horror'     THEN 'horror'
        WHEN 'Adventure'  THEN 'adventure'
        WHEN 'Mystery'    THEN 'mystery'
        WHEN 'Romance'    THEN 'romance'
        WHEN 'Comedy'     THEN 'comedy'
        WHEN 'Thriller'   THEN 'thriller'
        WHEN 'Historical' THEN 'historical'
        WHEN 'History'    THEN 'historical'
        WHEN 'Drama'      THEN 'drama'
        ELSE q.category
      END
WHERE cardinality(COALESCE(q.genres, '{}'::text[])) = 0
  AND q.category IS NOT NULL;

COMMIT;

-- Проверка после применения: старых подписей остаться не должно.
-- SELECT genres, count(*) FROM quests GROUP BY genres ORDER BY count(*) DESC;
