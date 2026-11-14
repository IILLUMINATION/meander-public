-- Вложения в личных сообщениях и новостях команды.
--
-- Массив объектов {url, width, height, size, mime}: сообщение может быть
-- альбомом (до 5 фото), и порядок кадров задаёт автор. Отдельная таблица
-- потребовала бы join на каждое сообщение ради 0–5 строк, а по вложениям
-- никогда не ищут отдельно от сообщения.
--
-- Ссылки абсолютные (publicUrl), потому что клиент один и тот же на всех
-- зеркалах: относительный путь пришлось бы склеивать с текущим зеркалом, а
-- файл лежит на одном.

ALTER TABLE dm_messages
    ADD COLUMN IF NOT EXISTS attachments JSONB NOT NULL DEFAULT '[]'::jsonb;

-- Тело может быть пустым, если пришли только фото: раньше NOT NULL и пустая
-- строка были одним и тем же, теперь это разные вещи.
ALTER TABLE dm_messages
    ALTER COLUMN body SET DEFAULT '';

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
    FOREACH t IN ARRAY ARRAY['dm_messages'] LOOP
        EXECUTE format('ALTER TABLE %I OWNER TO %I', t, app_role);
    END LOOP;
END $$;