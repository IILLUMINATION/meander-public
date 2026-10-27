-- 1. Создание типов (ENUM)
DO $$ BEGIN
    CREATE TYPE quest_status AS ENUM ('in_review', 'published', 'rejected');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE review_status AS ENUM ('pending', 'approved', 'rejected');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- 2. Таблица профилей
CREATE TABLE IF NOT EXISTS profiles (
    id UUID PRIMARY KEY,
    full_name TEXT,
    avatar_url TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    role TEXT DEFAULT 'user',
    bio TEXT,
    is_verified BOOLEAN DEFAULT FALSE,
    ad_free_until TIMESTAMPTZ,
    google_id TEXT UNIQUE,
    email TEXT UNIQUE,
    last_published_at TIMESTAMPTZ,
    is_blocked BOOLEAN DEFAULT FALSE
);

-- 3. Таблица квестов
CREATE TABLE IF NOT EXISTS quests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    download_url TEXT NOT NULL,
    preview_image_url TEXT,
    title TEXT NOT NULL,
    description TEXT,
    downloads_count INTEGER DEFAULT 0,
    version TEXT DEFAULT '1.0.0',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    status quest_status DEFAULT 'in_review',
    author_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    moderator_comment TEXT,
    category TEXT,
    file_hash TEXT,
    is_featured BOOLEAN DEFAULT FALSE,
    like_count INTEGER DEFAULT 0,
    dislike_count INTEGER DEFAULT 0,
    quest_size_bytes BIGINT DEFAULT 0,
    node_count INTEGER DEFAULT 0,
    estimated_playtime INTEGER DEFAULT 0,
    github_release_id BIGINT,
    is_demo BOOLEAN DEFAULT FALSE,
    market_tier SMALLINT NOT NULL DEFAULT 2,
    CONSTRAINT quests_market_tier_range CHECK (market_tier IN (1, 2, 3)),
    CONSTRAINT quests_market_tier_matches_demo CHECK ((market_tier = 3) = COALESCE(is_demo, FALSE))
);
CREATE INDEX IF NOT EXISTS idx_quests_file_hash ON quests(file_hash);
CREATE INDEX IF NOT EXISTS idx_quests_published_market_tier
    ON quests (market_tier, created_at DESC)
    WHERE status = 'published';

-- 4. Ачивки
CREATE TABLE IF NOT EXISTS achievements (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    icon_name TEXT NOT NULL,
    xp_reward INTEGER DEFAULT 10,
    is_secret BOOLEAN DEFAULT FALSE,
    category TEXT DEFAULT 'common'
);

-- 5. Ачивки юзеров
CREATE TABLE IF NOT EXISTS user_achievements (
    user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
    achievement_id TEXT REFERENCES achievements(id) ON DELETE CASCADE,
    achieved_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id, achievement_id)
);

-- 6. Отзывы
CREATE TABLE IF NOT EXISTS reviews (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quest_id UUID NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
    author_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    text_content TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    status review_status DEFAULT 'pending'
);

-- 7. Рейтинги
CREATE TABLE IF NOT EXISTS ratings (
    quest_id UUID NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    rating SMALLINT NOT NULL CHECK (rating >= 1 AND rating <= 5),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (quest_id, user_id)
);

-- 8. Лайки/Дизлайки
CREATE TABLE IF NOT EXISTS quest_votes (
    quest_id UUID NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    is_like BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (quest_id, user_id)
);

-- 9. Скриншоты
CREATE TABLE IF NOT EXISTS quest_screenshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quest_id UUID NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
    image_url TEXT NOT NULL,
    sort_order SMALLINT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 10. Подписки
CREATE TABLE IF NOT EXISTS user_followers (
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    follower_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id, follower_id)
);

-- 11. Уникальные скачивания
CREATE TABLE IF NOT EXISTS quest_downloads (
    user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
    quest_id UUID REFERENCES quests(id) ON DELETE CASCADE,
    downloaded_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id, quest_id)
);

-- 12. ПРОМОКОДЫ (НОВОЕ)
CREATE TABLE IF NOT EXISTS promo_codes (
    code TEXT PRIMARY KEY,
    days_duration INTEGER NOT NULL DEFAULT 30, -- Сколько дней премиума дает
    max_uses INTEGER DEFAULT 1000,             -- Сколько раз можно активировать всего
    current_uses INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE
);

-- 13. ИСТОРИЯ АКТИВАЦИЙ (НОВОЕ)
CREATE TABLE IF NOT EXISTS promo_code_usages (
    user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
    code TEXT REFERENCES promo_codes(code) ON DELETE CASCADE,
    activated_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id, code)
);

-- 14. ТАБЛИЦА ЖАЛОБ
CREATE TABLE IF NOT EXISTS reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    reported_type TEXT NOT NULL CHECK (reported_type IN ('quest', 'review', 'user', 'wall_post', 'wall_comment', 'asset', 'music')),
    reported_id UUID NOT NULL,
    reason TEXT NOT NULL,
    description TEXT,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'resolved', 'dismissed')),
    resolved_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_reports_status ON reports(status);
CREATE INDEX IF NOT EXISTS idx_reports_reported ON reports(reported_type, reported_id);

-- 15. NOTIFICATIONS
CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    actor_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    type TEXT NOT NULL,
    quest_id UUID REFERENCES quests(id) ON DELETE SET NULL,
    review_id UUID REFERENCES reviews(id) ON DELETE SET NULL,
    payload JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    read_at TIMESTAMPTZ,
    archived_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_archived ON notifications(user_id, archived_at);

-- 14. VIEW
CREATE OR REPLACE VIEW market_quests AS
SELECT
    q.*,
    p.full_name AS author_name,
    p.is_verified AS author_is_verified,
    (SELECT AVG(r.rating) FROM ratings r WHERE r.quest_id = q.id) AS average_rating
FROM
    quests q
LEFT JOIN
    profiles p ON q.author_id = p.id;

-- 15. ДАННЫЕ
INSERT INTO achievements (id, name, description, icon_name, category, is_secret, xp_reward) VALUES
('hello_world', 'Hello World', 'Зарегистрироваться в приложении.', 'login', 'common', false, 5),
('first_step', 'Первый шаг', 'Скачать первый квест.', 'download', 'common', false, 10),
('critic_bronze', 'Диванный критик', 'Оставить первый отзыв.', 'rate_review', 'social', false, 10),
('observer', 'Наблюдатель', 'Посмотреть детали 10 разных квестов.', 'visibility', 'explorer', false, 5),
('profile_pic', 'Лицо компании', 'Установить аватарку.', 'face', 'social', false, 10),
('publisher_debut', 'В печать!', 'Опубликовать первый квест.', 'publish', 'creator', false, 50),
('bookworm', 'Книжный червь', 'Скачать 10 квестов.', 'library_books', 'explorer', false, 30),
('library_keeper', 'Библиотекарь', 'Скачать 50 квестов.', 'local_library', 'explorer', false, 100),
('social_butterfly', 'Душа компании', 'Подписаться на 5 авторов.', 'group_add', 'social', false, 20),
('generous', 'Меценат', 'Поставить лайк 20 разным квестам.', 'volunteer_activism', 'social', false, 30)
ON CONFLICT (id) DO NOTHING;

-- Music library
DO $$ BEGIN
    CREATE TYPE music_status AS ENUM ('in_review', 'published', 'rejected');
EXCEPTION WHEN duplicate_object THEN null;
END $$;
CREATE TABLE IF NOT EXISTS music_tracks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    performer TEXT NOT NULL,
    description TEXT,
    genre TEXT,
    genres TEXT[] DEFAULT '{}',
    file_url TEXT NOT NULL,
    cover_url TEXT,
    license TEXT NOT NULL DEFAULT 'CC-BY',
    duration_seconds INTEGER DEFAULT 0,
    file_hash TEXT,
    file_size_bytes BIGINT DEFAULT 0,
    status music_status DEFAULT 'in_review',
    author_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_music_tracks_status ON music_tracks(status);
CREATE INDEX IF NOT EXISTS idx_music_tracks_genre ON music_tracks(genre);
CREATE INDEX IF NOT EXISTS idx_music_tracks_created ON music_tracks(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_music_tracks_author ON music_tracks(author_id);

-- Generic asset market
DO $$ BEGIN
    CREATE TYPE asset_kind AS ENUM ('button_preset', 'background', 'image', 'sfx', 'font', 'music');
EXCEPTION WHEN duplicate_object THEN null;
END $$;
DO $$ BEGIN
    CREATE TYPE asset_status AS ENUM ('in_review', 'published', 'rejected');
EXCEPTION WHEN duplicate_object THEN null;
END $$;
CREATE TABLE IF NOT EXISTS market_assets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind asset_kind NOT NULL,
    title TEXT NOT NULL,
    author_name TEXT,
    description TEXT,
    genre TEXT,
    genres TEXT[] DEFAULT '{}',
    file_url TEXT NOT NULL,
    cover_url TEXT,
    preview_url TEXT,
    license TEXT NOT NULL DEFAULT 'CC-BY',
    file_hash TEXT,
    file_size_bytes BIGINT DEFAULT 0,
    status asset_status DEFAULT 'in_review',
    author_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_market_assets_kind ON market_assets(kind);
CREATE INDEX IF NOT EXISTS idx_market_assets_status ON market_assets(status);
CREATE INDEX IF NOT EXISTS idx_market_assets_created ON market_assets(created_at DESC);

-- ТЕСТОВЫЙ ПРОМОКОД (Дает 30 дней без рекламы)
INSERT INTO promo_codes (code, days_duration, max_uses) 
VALUES ('MEANDER2025', 30, 10000)
ON CONFLICT (code) DO NOTHING;
