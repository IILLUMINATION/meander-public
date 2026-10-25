-- Заходы по дням: без них видно только «когда человек был последний раз»,
-- а дашборд не может ответить ни «сколько раз он заходил», ни «сколько людей
-- было в приложении вчера».
--
-- Строка — (человек, сутки), счётчик визитов внутри суток. Визит — сессия,
-- а не запрос: middleware увеличивает счётчик не чаще раза в 30 минут, чтобы
-- один открытый экран не превращался в сотню «заходов».
CREATE TABLE IF NOT EXISTS user_activity_daily (
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    day DATE NOT NULL,
    visits INTEGER NOT NULL DEFAULT 0,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, day)
);

-- Ряд по дням для дашборда.
CREATE INDEX IF NOT EXISTS idx_user_activity_daily_day ON user_activity_daily(day);
-- «Кто активнее всех» за период.
CREATE INDEX IF NOT EXISTS idx_user_activity_daily_user ON user_activity_daily(user_id, day);

-- Владение — как в add_forums.sql: таблицы, созданные superuser, приложение
-- не увидит ни в одном запросе.
DO $$
DECLARE
    app_role text;
BEGIN
    SELECT r.rolname INTO app_role
      FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner
     WHERE c.relname = 'profiles' AND c.relnamespace = 'public'::regnamespace;
    IF app_role IS NULL THEN
        RAISE NOTICE 'роль приложения не найдена — владение не менялось';
        RETURN;
    END IF;
    EXECUTE format('ALTER TABLE %I OWNER TO %I', 'user_activity_daily', app_role);
END $$;
