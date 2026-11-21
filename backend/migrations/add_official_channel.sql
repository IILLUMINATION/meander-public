-- Официальный канал новостей: публиковать может только владелец.
--
-- Раньше «Новости Meander» ничем не отличался от обычного канала: писать
-- могли владелец и назначенные админы. Для канала от лица проекта это
-- слишком широкое право — одна случайная публикация уходит всем подписчикам.
-- Флаг is_official отделяет новостной канал от пользовательских, не меняя
-- правила для остальных каналов.

ALTER TABLE channels
    ADD COLUMN IF NOT EXISTS is_official BOOLEAN NOT NULL DEFAULT FALSE;

-- Официальный канал ровно один: уникальный индекс по TRUE не даст завести
-- второй и тем самым обойти проверку в API.
CREATE UNIQUE INDEX IF NOT EXISTS idx_channels_one_official
    ON channels (is_official)
    WHERE is_official;

UPDATE channels
   SET is_official = TRUE
 WHERE lower(title) = lower('Новости Meander');

DO $$
DECLARE
    app_role text;
BEGIN
    SELECT r.rolname INTO app_role
      FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner
     WHERE c.relname = 'channels' AND c.relnamespace = 'public'::regnamespace;
    IF app_role IS NOT NULL THEN
        EXECUTE format('ALTER TABLE channels OWNER TO %I', app_role);
    END IF;
END $$;