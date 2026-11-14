-- Поддержка: одно окно «Поддержка» на человека, обращения внутри него.
--
-- Модель: у пользователя есть лента support_messages (бот + его сообщения и
-- ответы команды). Пока открытых обращений нет — на его текст отвечает бот.
-- Как только обращение создано, свободный текст уходит в него и рассылается
-- всем админам: у них один общий инбокс, а не личный диалог с каждым.
--
-- Почему не dm_threads: личный диалог — это пара участников, и «всем админам»
-- в такой схеме не выражается. Обращение же имеет одного автора, произвольное
-- число ответчиков и статус.

CREATE TABLE IF NOT EXISTS support_tickets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    subject TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'other',
    -- open — ждёт команду, answered — ответили и ждём автора, closed — закрыто.
    status TEXT NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'answered', 'closed')),
    priority SMALLINT NOT NULL DEFAULT 2,
    language TEXT NOT NULL DEFAULT 'ru',
    assigned_admin_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_message_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    closed_by UUID REFERENCES profiles(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_support_tickets_status
    ON support_tickets (status, last_message_at DESC);
CREATE INDEX IF NOT EXISTS idx_support_tickets_user
    ON support_tickets (user_id, created_at DESC);

-- Лента окна «Поддержка». ticket_id = NULL — это разговор с ботом вне
-- обращения (меню, FAQ). role='bot' пишет система, role='staff' — команда.
CREATE TABLE IF NOT EXISTS support_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    ticket_id UUID REFERENCES support_tickets(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    role TEXT NOT NULL CHECK (role IN ('user', 'bot', 'staff', 'system')),
    body TEXT NOT NULL DEFAULT '',
    attachments JSONB NOT NULL DEFAULT '[]'::jsonb,
    -- Inline-кнопки: [{id, label, action, payload}]. Хранятся вместе с
    -- сообщением, чтобы история не зависела от текущей версии бота.
    buttons JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_support_messages_user
    ON support_messages (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_support_messages_ticket
    ON support_messages (ticket_id, created_at);

-- Состояние диалога с ботом: язык и «что ждём от человека следующим сообщением».
CREATE TABLE IF NOT EXISTS support_sessions (
    user_id UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
    language TEXT NOT NULL DEFAULT 'ru',
    state JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Кто из админов прочитал обращение: у инбокса несколько читателей, и один
-- общий счётчик непрочитанного на всех искажал бы работу.
CREATE TABLE IF NOT EXISTS support_staff_reads (
    ticket_id UUID NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
    admin_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    last_read_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (ticket_id, admin_id)
);

-- Владение: миграции исполняет superuser, приложение ходит своей ролью.
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
        'support_tickets', 'support_messages', 'support_sessions', 'support_staff_reads'
    ] LOOP
        EXECUTE format('ALTER TABLE %I OWNER TO %I', t, app_role);
    END LOOP;
END $$;