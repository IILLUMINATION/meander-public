-- Три уровня маркета.
--
-- 1 — лучшие: отобраны вручную, идеальные и доделанные квесты;
-- 2 — прошедшие модерацию, не демо;
-- 3 — демо-версии, самый низ каталога.
--
-- Уровень ставит бэкенд: при публикации — 2 или 3 (демо), админ может
-- вручную поднять до 1. Инвариант: демо всегда уровень 3, уровни 1–2 —
-- всегда не демо. Поэтому в check-условии оба флага связаны.
--
-- Запуск (на проде — только вместе с деплоем бэкенда):
--   sudo -u postgres psql -d meander_db -v ON_ERROR_STOP=1 -f migration_market_tiers.sql
--
-- Откат: см. хвост файла (вернуть view без market_tier и удалить колонку).

BEGIN;

-- Копия флагов до правки: уровень выводится из них, и после миграции
-- должно остаться чем сверить результат.
CREATE TABLE IF NOT EXISTS quests_market_tier_backup_20261027 AS
SELECT id, is_demo, is_featured, created_at FROM quests;

ALTER TABLE quests ADD COLUMN IF NOT EXISTS market_tier SMALLINT;
ALTER TABLE quests ALTER COLUMN market_tier SET DEFAULT 2;
ALTER TABLE quests ALTER COLUMN market_tier DROP NOT NULL;

-- Бэкфилл: существующие featured — уровень 1 (их и так отбирали вручную),
-- демо — 3, остальные — 2.
UPDATE quests SET market_tier = 2 WHERE market_tier IS NULL;
UPDATE quests SET market_tier = 3 WHERE market_tier = 2 AND is_demo;
UPDATE quests SET market_tier = 1 WHERE market_tier = 2 AND is_featured AND NOT is_demo;

ALTER TABLE quests ALTER COLUMN market_tier SET NOT NULL;

DO $$ BEGIN
    ALTER TABLE quests ADD CONSTRAINT quests_market_tier_range
        CHECK (market_tier IN (1, 2, 3));
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    ALTER TABLE quests ADD CONSTRAINT quests_market_tier_matches_demo
        CHECK ((market_tier = 3) = COALESCE(is_demo, FALSE));
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- Каталог сортируется по уровню, затем по свежести.
CREATE INDEX IF NOT EXISTS idx_quests_published_market_tier
    ON quests (market_tier, created_at DESC)
    WHERE status = 'published';

-- На проде market_quests определён явным списком колонок — дописываем
-- market_tier в тот же список, а не заменяем view на q.*.
CREATE OR REPLACE VIEW market_quests AS
SELECT q.id,
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
    q.market_tier,
    p.full_name AS author_name,
    p.is_verified AS author_is_verified,
    (SELECT AVG(r.rating) AS avg FROM ratings r WHERE r.quest_id = q.id) AS average_rating,
    q.language
FROM quests q
LEFT JOIN profiles p ON q.author_id = p.id;

COMMIT;

-- Откат (выполнять отдельно, после отката бэкенда):
--   BEGIN;
--   CREATE OR REPLACE VIEW market_quests AS /* прежнее определение без market_tier */;
--   ALTER TABLE quests DROP CONSTRAINT IF EXISTS quests_market_tier_matches_demo;
--   ALTER TABLE quests DROP CONSTRAINT IF EXISTS quests_market_tier_range;
--   DROP INDEX IF EXISTS idx_quests_published_market_tier;
--   ALTER TABLE quests DROP COLUMN IF EXISTS market_tier;
--   COMMIT;
