-- Каналы: лента публикаций от одного автора (или команды), с подпиской.
--
-- От сообществ отличаются направлением: писать может владелец и его админы,
-- остальные читают. Комментарии — под постом, а не общий чат: у канала тысячи
-- подписчиков, и общая лента сообщений превращается в мусорку.
--
-- Подписчик — строка в channel_subscribers с ролью. Отдельного счётчика
-- «подписан ли я» нет: одна таблица отвечает и на это, и на права.

CREATE TABLE IF NOT EXISTS channels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    slug TEXT UNIQUE,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    avatar_url TEXT,
    is_public BOOLEAN NOT NULL DEFAULT TRUE,
    comments_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    subscribers_count INTEGER NOT NULL DEFAULT 0,
    posts_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_post_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_channels_owner ON channels (owner_id);
CREATE INDEX IF NOT EXISTS idx_channels_public
    ON channels (is_public, subscribers_count DESC);

CREATE TABLE IF NOT EXISTS channel_subscribers (
    channel_id UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'subscriber'
        CHECK (role IN ('owner', 'admin', 'subscriber')),
    muted BOOLEAN NOT NULL DEFAULT FALSE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_read_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (channel_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_channel_subscribers_user
    ON channel_subscribers (user_id, joined_at DESC);

CREATE TABLE IF NOT EXISTS channel_posts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    channel_id UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    author_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    body TEXT NOT NULL DEFAULT '',
    attachments JSONB NOT NULL DEFAULT '[]'::jsonb,
    views_count INTEGER NOT NULL DEFAULT 0,
    comments_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    edited_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_channel_posts_feed
    ON channel_posts (channel_id, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS channel_comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id UUID NOT NULL REFERENCES channel_posts(id) ON DELETE CASCADE,
    author_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_channel_comments_post
    ON channel_comments (post_id, created_at)
    WHERE deleted_at IS NULL;

-- Просмотры: без отдельной таблицы «кто смотрел», но с защитой от накрутки
-- одним и тем же человеком.
CREATE TABLE IF NOT EXISTS channel_post_views (
    post_id UUID NOT NULL REFERENCES channel_posts(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (post_id, user_id)
);

DO $$
DECLARE
    app_role text;
    t text;
BEGIN
    SELECT r.rolname INTO app_role
      FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner
     WHERE c.relname = 'profiles' AND c.relnamespace = 'public'::regnamespace;
    IF app_role IS NULL THEN
        RAISE NOTICE 'роль приложения не найдена — владение не менялось';
        RETURN;
    END IF;
    FOREACH t IN ARRAY ARRAY[
        'channels', 'channel_subscribers', 'channel_posts',
        'channel_comments', 'channel_post_views'
    ] LOOP
        EXECUTE format('ALTER TABLE %I OWNER TO %I', t, app_role);
    END LOOP;
END $$;