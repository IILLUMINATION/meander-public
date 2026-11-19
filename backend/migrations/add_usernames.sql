-- Юзернеймы: короткий @адрес вместо uuid.
--
-- У каналов колонка slug была с самого начала, но нигде не заполнялась; у
-- профилей адреса не было вовсе. Оба вида живут в одном пространстве имён:
-- `@meander` не может быть одновременно человеком и каналом, иначе упоминание
-- неоднозначно. Уникальность проверяется без учёта регистра.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS username TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_username_lower
    ON profiles (lower(username))
    WHERE username IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_channels_slug_lower
    ON channels (lower(slug))
    WHERE slug IS NOT NULL;
