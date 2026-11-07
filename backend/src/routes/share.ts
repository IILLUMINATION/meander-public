import { Router, Request, Response } from 'express';
import pool from '../config/database';
import { validate as uuidValidate } from 'uuid'; // ИМПОРТ

const router = Router();

// SEC-19: переход в приложение вынесен из HTML в статический скрипт, чтобы CSP
// не разрешала исполнять произвольный инлайн-код. Ссылка передаётся через
// <meta>, которую браузер не исполняет.
router.get('/redirect.js', (_req: Request, res: Response) => {
    res.type('application/javascript').send(
        "window.addEventListener('load',function(){var m=document.querySelector('meta[name=\"meander-app-link\"]');if(m){var u=m.getAttribute('content');if(u){setTimeout(function(){window.location.href=u;},500);}}});"
    );
});

// Твоя ссылка на Google Play
const GOOGLE_PLAY_LINK = "https://play.google.com/store/apps/details?id=com.IILLUMINAT.meadner";
const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';

const escapeHtml = (value: unknown): string =>
    String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');

const sanitizeHttpUrl = (url: string, fallback: string): string => {
    try {
        const parsed = new URL(url);
        if (parsed.protocol === 'http:' || parsed.protocol === 'https:') {
            return parsed.toString();
        }
        return fallback;
    } catch {
        return fallback;
    }
};

// Шаблон HTML страницы

const renderHtml = (title: string, description: string, imageUrl: string, appSchemeLink: string, type: 'Quest' | 'Profile') => {
    const safeTitle = escapeHtml(title);
    const safeDescription = escapeHtml(description).replace(/\n/g, '<br>');
    const safeImageUrl = escapeHtml(sanitizeHttpUrl(imageUrl, `${BASE_URL}/uploads/${type === 'Quest' ? 'default_cover.jpg' : 'default_avatar.jpg'}`));
    const safeAppLink = escapeHtml(appSchemeLink);
    const safeTypeBadge = type === 'Quest' ? 'КВЕСТ' : 'ПРОФИЛЬ';

    const isProfile = type === 'Profile';

    return `
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <meta name="referrer" content="no-referrer">
    <meta name="meander-app-link" content="${safeAppLink}">

    <meta property="og:type" content="website">
    <meta property="og:title" content="${safeTitle}">
    <meta property="og:description" content="${escapeHtml(description).substring(0, 150)}...">
    <meta property="og:image" content="${safeImageUrl}">
    
    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:title" content="${safeTitle}">
    <meta name="twitter:description" content="${escapeHtml(description).substring(0, 150)}...">
    <meta name="twitter:image" content="${safeImageUrl}">

    <title>${safeTitle} | Meander</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700&display=swap" rel="stylesheet">

    <style>
        :root {
            --md-sys-color-surface: #141218;
            --md-sys-color-on-surface: #E6E0E9;
            --md-sys-color-on-surface-variant: #CAC4D0;
            --md-sys-color-surface-container-high: #2B2930;
            --md-sys-color-primary: #D0BCFF;
            --md-sys-color-on-primary: #381E72;
            --md-sys-color-secondary-container: #4A4458;
            --md-sys-color-on-secondary-container: #E8DEF8;
            --md-sys-color-tertiary-container: #4D4357;
            --md-sys-color-on-tertiary-container: #E8DEF8;
        }
        
        * { box-sizing: border-box; }

        body {
            background-color: var(--md-sys-color-surface);
            color: var(--md-sys-color-on-surface);
            font-family: 'Roboto', sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            padding: 20px;
        }

        .logo { 
            margin-bottom: 24px; 
            font-weight: 700; 
            font-size: 22px;
            letter-spacing: 1px; 
            color: var(--md-sys-color-primary);
        }

        .card {
            background-color: var(--md-sys-color-surface-container-high);
            border-radius: 28px;
            padding: 24px;
            width: 100%;
            max-width: 420px;
            box-shadow: 0 8px 16px rgba(0,0,0,0.3);
            animation: slideUp 0.5s cubic-bezier(0.2, 0, 0, 1);
            display: flex;
            flex-direction: column;
            align-items: center;
            text-align: center;
        }

        .img-container {
            width: ${isProfile ? '120px' : '100%'};
            height: ${isProfile ? '120px' : '200px'};
            border-radius: ${isProfile ? '50%' : '20px'};
            overflow: hidden;
            margin-bottom: 20px;
            background-color: var(--md-sys-color-secondary-container);
            flex-shrink: 0;
        }

        .img-container img {
            width: 100%;
            height: 100%;
            object-fit: cover;
            display: block;
        }

        .badge {
            display: inline-block;
            background: var(--md-sys-color-tertiary-container);
            color: var(--md-sys-color-on-tertiary-container);
            padding: 4px 12px;
            border-radius: 8px;
            font-size: 12px;
            font-weight: 500;
            margin-bottom: 16px;
            letter-spacing: 0.5px;
        }

        h1 { 
            margin: 0 0 12px; 
            font-size: 24px; 
            font-weight: 700;
            line-height: 1.3;
            color: var(--md-sys-color-on-surface);
        }

        p { 
            color: var(--md-sys-color-on-surface-variant); 
            font-size: 16px; 
            line-height: 1.5; 
            margin: 0 0 32px; 
            display: -webkit-box;
            -webkit-line-clamp: 4;
            -webkit-box-orient: vertical;
            overflow: hidden;
        }

        .actions {
            display: flex;
            flex-direction: column;
            gap: 12px;
            width: 100%;
        }

        .btn {
            text-decoration: none;
            padding: 16px;
            border-radius: 100px;
            font-weight: 500;
            font-size: 15px;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: background-color 0.2s;
            cursor: pointer;
            letter-spacing: 0.1px;
            width: 100%;
        }

        .btn-primary {
            background-color: var(--md-sys-color-primary);
            color: var(--md-sys-color-on-primary);
        }
        .btn-primary:active { background-color: #e0cffc; }

        .btn-tonal {
            background-color: var(--md-sys-color-secondary-container);
            color: var(--md-sys-color-on-secondary-container);
        }
        .btn-tonal:active { background-color: #5c556b; }

        @keyframes slideUp {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }
    </style>
</head>
<body>
    <div class="logo">Meander</div>
    
    <div class="card">
        <div class="img-container">
            <img src="${safeImageUrl}" alt="Cover" referrerpolicy="no-referrer">
        </div>
        
        <div class="badge">${safeTypeBadge}</div>
        <h1>${safeTitle}</h1>
        <p>${safeDescription}</p>

        <div class="actions">
            <a href="${safeAppLink}" class="btn btn-primary">
                Открыть в приложении
            </a>
            <a href="${GOOGLE_PLAY_LINK}" class="btn btn-tonal">
                Скачать Meander
            </a>
        </div>
    </div>
    
    <script src="/share/redirect.js"></script>
</body>
</html>
`;
};
const renderPostHtml = (authorName: string, authorAvatar: string, content: string, appSchemeLink: string) => {
    const safeName = escapeHtml(authorName);
    const safeContent = escapeHtml(content).replace(/\n/g, '<br>');
    const safeAvatar = escapeHtml(sanitizeHttpUrl(authorAvatar, `${BASE_URL}/uploads/default_avatar.jpg`));
    const safeAppLink = escapeHtml(appSchemeLink);

    return `
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <meta name="referrer" content="no-referrer">
    <meta name="meander-app-link" content="${safeAppLink}">

    <meta property="og:type" content="article">
    <meta property="og:title" content="Пост от ${safeName}">
    <meta property="og:description" content="${escapeHtml(content).substring(0, 150)}...">
    <meta property="og:image" content="${safeAvatar}">
    
    <meta name="twitter:card" content="summary">
    <meta name="twitter:title" content="Пост от ${safeName}">
    <meta name="twitter:description" content="${escapeHtml(content).substring(0, 150)}...">
    <meta name="twitter:image" content="${safeAvatar}">

    <title>Пост от ${safeName} | Meander</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700&display=swap" rel="stylesheet">

    <style>
        :root {
            --md-sys-color-surface: #141218;
            --md-sys-color-on-surface: #E6E0E9;
            --md-sys-color-on-surface-variant: #CAC4D0;
            --md-sys-color-surface-container-high: #2B2930;
            --md-sys-color-primary: #D0BCFF;
            --md-sys-color-on-primary: #381E72;
            --md-sys-color-secondary-container: #4A4458;
            --md-sys-color-on-secondary-container: #E8DEF8;
            --md-sys-color-primary-container: #4F378B;
            --md-sys-color-on-primary-container: #EADDFF;
        }
        
        * { box-sizing: border-box; }

        body {
            background-color: var(--md-sys-color-surface);
            color: var(--md-sys-color-on-surface);
            font-family: 'Roboto', sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            padding: 20px;
        }

        .post-card {
            background-color: var(--md-sys-color-surface-container-high);
            border-radius: 24px;
            padding: 20px;
            width: 100%;
            max-width: 450px;
            box-shadow: 0 4px 8px rgba(0,0,0,0.2);
            animation: slideUp 0.5s cubic-bezier(0.2, 0, 0, 1);
        }

        .author-row {
            display: flex;
            align-items: center;
            gap: 16px;
            margin-bottom: 16px;
        }

        .avatar {
            width: 48px;
            height: 48px;
            border-radius: 50%;
            object-fit: cover;
            background-color: var(--md-sys-color-primary-container);
        }

        .author-info {
            display: flex;
            flex-direction: column;
        }

        .author-name {
            font-size: 16px;
            font-weight: 500;
            margin: 0;
            color: var(--md-sys-color-on-surface);
        }

        .community-label {
            font-size: 14px;
            font-weight: 400;
            margin: 2px 0 0;
            color: var(--md-sys-color-on-surface-variant);
        }

        .post-content {
            font-size: 16px;
            line-height: 1.5;
            margin: 0 0 24px;
            color: var(--md-sys-color-on-surface);
            word-wrap: break-word;
        }

        .actions {
            display: flex;
            flex-direction: column;
            gap: 12px;
        }

        .btn {
            text-decoration: none;
            padding: 14px 24px;
            border-radius: 100px;
            font-weight: 500;
            font-size: 14px;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: background-color 0.2s;
            cursor: pointer;
            letter-spacing: 0.1px;
        }

        .btn-primary {
            background-color: var(--md-sys-color-primary);
            color: var(--md-sys-color-on-primary);
        }

        .btn-primary:active {
            background-color: #e0cffc;
        }

        .btn-tonal {
            background-color: var(--md-sys-color-secondary-container);
            color: var(--md-sys-color-on-secondary-container);
        }

        .btn-tonal:active {
            background-color: #5c556b;
        }

        @keyframes slideUp {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }
    </style>
</head>
<body>
    <div class="post-card">
        <div class="author-row">
            <img src="${safeAvatar}" alt="${safeName}" class="avatar" referrerpolicy="no-referrer">
            <div class="author-info">
                <h2 class="author-name">${safeName}</h2>
                <p class="community-label">Сообщество Meander</p>
            </div>
        </div>
        
        <div class="post-content">
            ${safeContent}
        </div>

        <div class="actions">
            <a href="${safeAppLink}" class="btn btn-primary">
                Читать в приложении
            </a>
            <a href="${GOOGLE_PLAY_LINK}" class="btn btn-tonal">
                Скачать Meander
            </a>
        </div>
    </div>
    
    <script src="/share/redirect.js"></script>
</body>
</html>
`;
};


// 1. Ссылка на КВЕСТ: /share/quest/:id
router.get('/quest/:id', async (req: Request, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(404).send('Invalid ID'); // ЗАЩИТА (возвращаем 404 для браузера)

    try {
        // Статус проверяется здесь же, где и в GET /quests/:id: иначе
        // квест на ревью или отклонённый отдавал название, описание и
        // обложку по публичной ссылке, хотя само приложение на этот же id
        // отвечало 404.
        const result = await pool.query(
            `SELECT title, description, preview_image_url FROM quests
             WHERE id = $1 AND status = 'published'`,
            [id]
        );

        if (result.rows.length === 0) {
            return res.status(404).send('Квест не найден');
        }

        const quest = result.rows[0];
        const appSchemeLink = `meander://share/quest/${id}`;
        
        // Обрезаем описание, чтобы не ломало верстку
        const desc = quest.description 
            ? (quest.description.length > 150 ? quest.description.substring(0, 150) + '...' : quest.description)
            : 'Увлекательный текстовый квест в Meander.';

        // Дефолтная картинка, если у квеста её нет
        const img = quest.preview_image_url || `${BASE_URL}/uploads/default_cover.jpg`;

        res.send(renderHtml(quest.title, desc, img, appSchemeLink, 'Quest'));

    } catch (e) {
        console.error(e);
        res.status(500).send('Ошибка сервера');
    }
});

// 2. Ссылка на ПРОФИЛЬ: /share/profile/:id
router.get('/profile/:id', async (req: Request, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(404).send('Invalid ID'); // ЗАЩИТА

    try {
        const result = await pool.query(
            `SELECT full_name, bio, avatar_url FROM profiles WHERE id = $1`,
            [id]
        );

        if (result.rows.length === 0) {
            return res.status(404).send('Пользователь не найден');
        }

        const user = result.rows[0];
        const appSchemeLink = `meander://share/profile/${id}`;
        
        const title = `${user.full_name}`;
        const desc = user.bio 
            ? (user.bio.length > 150 ? user.bio.substring(0, 150) + '...' : user.bio)
            : 'Автор и игрок в текстовые квесты Meander.';
        
        const img = user.avatar_url || `${BASE_URL}/uploads/default_avatar.jpg`;

        res.send(renderHtml(title, desc, img, appSchemeLink, 'Profile'));

    } catch (e) {
        console.error(e);
        res.status(500).send('Ошибка сервера');
    }
});


// 3. Ссылка на ПОСТ: /share/post/:id
router.get('/post/:id', async (req: Request, res: Response) => {
    const { id } = req.params;
    if (!uuidValidate(id)) return res.status(404).send('Invalid ID'); // ЗАЩИТА

    try {
        const result = await pool.query(
            `SELECT ap.content, p.full_name, p.avatar_url 
             FROM author_posts ap
             JOIN profiles p ON ap.author_id = p.id
             WHERE ap.id = $1 AND ap.is_active = true`,
            [id]
        );

        if (result.rows.length === 0) {
            return res.status(404).send('Пост не найден');
        }

        const post = result.rows[0];
        const appSchemeLink = `meander://share/post/${id}`;
        
        res.send(renderPostHtml(post.full_name, post.avatar_url, post.content, appSchemeLink));

    } catch (e) {
        console.error(e);
        res.status(500).send('Ошибка сервера');
    }
});

export default router;
