-- ============================================================================
--  Миграция: слот «фон профиля» в косметике
--  Версия: profile_backgrounds
--  Применить: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/migration_profile_backgrounds.sql
--
--  Новый слот `background` (арт-фон на всю страницу профиля). Ограничение
--  user_cosmetics.slot было захардкожено списком из четырёх слотов — без его
--  расширения выдача фона упадёт на CHECK, хотя каталог его знает.
-- ============================================================================

ALTER TABLE user_cosmetics
    DROP CONSTRAINT IF EXISTS user_cosmetics_slot_check;

ALTER TABLE user_cosmetics
    ADD CONSTRAINT user_cosmetics_slot_check
    CHECK (slot IN ('banner','background','avatar_frame','name_style','effect'));
