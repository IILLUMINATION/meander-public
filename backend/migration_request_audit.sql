-- Аудит обращений к API: время, IP, пользователь, устройство.
--
-- Зачем: разбирать атаки и жалобы («кто это сделал»). IP приходит из
-- x-real-ip, который nginx переписывает с реального сокета (или из
-- CF-Connecting-IP на краю Cloudflare), поэтому подделать его снаружи нельзя.
--
-- user_id без внешнего ключа: журнал должен переживать удаление аккаунта
-- (иначе строка либо упадёт на FK, либо потеряет автора). Привязка к
-- profiles.id — логическая, по UUID.
--
-- device_id присылает клиент (X-Device-Id): случайный UUID, сгенерированный
-- при первой установке. Это не аппаратный идентификатор — правки кода не
-- хватает для переустановки.

CREATE TABLE IF NOT EXISTS request_visits (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ip INET,
    user_id UUID,
    device_id TEXT,
    platform TEXT,
    app_version TEXT,
    method TEXT NOT NULL,
    path TEXT NOT NULL,
    status INTEGER,
    user_agent TEXT,
    duration_ms INTEGER
);

-- Свежие записи и разбор инцидента по адресу.
CREATE INDEX IF NOT EXISTS request_visits_created_idx
    ON request_visits (created_at DESC);
CREATE INDEX IF NOT EXISTS request_visits_ip_idx
    ON request_visits (ip, created_at DESC);
CREATE INDEX IF NOT EXISTS request_visits_user_idx
    ON request_visits (user_id, created_at DESC);
-- Устройство ищут точечно, анонимных строк большинство — частичный индекс.
CREATE INDEX IF NOT EXISTS request_visits_device_idx
    ON request_visits (device_id, created_at DESC)
    WHERE device_id IS NOT NULL;

-- Сводка по адресу за сутки: всплеск 4xx/5xx — первое, что смотрят при атаке.
CREATE OR REPLACE VIEW request_visits_daily AS
SELECT
    date_trunc('day', created_at) AS day,
    ip,
    count(*) AS requests,
    count(*) FILTER (WHERE status >= 400) AS errors,
    count(DISTINCT user_id) AS users,
    count(DISTINCT device_id) AS devices,
    min(created_at) AS first_seen,
    max(created_at) AS last_seen
FROM request_visits
GROUP BY 1, 2;