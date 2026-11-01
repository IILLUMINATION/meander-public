-- Жалобы на личные сообщения.
-- Добавляет 'message' в reports.reported_type: маршрут /reports уже проверяет,
-- что сообщение принадлежит диалогу жалующегося и отправлено не им.
ALTER TABLE reports DROP CONSTRAINT IF EXISTS reports_reported_type_check;
ALTER TABLE reports ADD CONSTRAINT reports_reported_type_check
    CHECK (reported_type IN (
        'quest', 'review', 'user', 'wall_post', 'wall_comment',
        'asset', 'music', 'forum', 'message'
    ));
