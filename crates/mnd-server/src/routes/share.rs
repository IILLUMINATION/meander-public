//! `/share` — public OpenGraph preview pages for quests, profiles and wall posts.
//!
//! Port of `backend/src/routes/share.ts`. The HTML templates, default images and
//! `redirect.js` snippet are reproduced verbatim.

use std::sync::Arc;

use axum::{
    Router,
    body::Body,
    extract::{Path, State},
    http::{StatusCode, header},
    response::Response,
    routing::get,
};
use sqlx::Row;
use url::Url;
use uuid::Uuid;

use crate::error::{ApiError, ApiResult};
use crate::state::AppState;

const GOOGLE_PLAY_LINK: &str =
    "https://play.google.com/store/apps/details?id=com.IILLUMINAT.meadner";

const REDIRECT_JS: &str = "window.addEventListener('load',function(){var m=document.querySelector('meta[name=\"meander-app-link\"]');if(m){var u=m.getAttribute('content');if(u){setTimeout(function(){window.location.href=u;},500);}}});";

const QUEST_HTML: &str = r#"<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <meta name="referrer" content="no-referrer">
    <meta name="meander-app-link" content="__APP_LINK__">

    <meta property="og:type" content="website">
    <meta property="og:title" content="__TITLE__">
    <meta property="og:description" content="__OG_DESCRIPTION__">
    <meta property="og:image" content="__IMAGE_URL__">

    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:title" content="__TITLE__">
    <meta name="twitter:description" content="__OG_DESCRIPTION__">
    <meta name="twitter:image" content="__IMAGE_URL__">

    <title>__TITLE__ | Meander</title>
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
            width: __IMG_WIDTH__;
            height: __IMG_HEIGHT__;
            border-radius: __IMG_RADIUS__;
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
            <img src="__IMAGE_URL__" alt="Cover" referrerpolicy="no-referrer">
        </div>

        <div class="badge">__TYPE_BADGE__</div>
        <h1>__TITLE__</h1>
        <p>__DESCRIPTION__</p>

        <div class="actions">
            <a href="__APP_LINK__" class="btn btn-primary">
                Открыть в приложении
            </a>
            <a href="__GOOGLE_PLAY_LINK__" class="btn btn-tonal">
                Скачать Meander
            </a>
        </div>
    </div>

    <script src="/share/redirect.js"></script>
</body>
</html>"#;

const POST_HTML: &str = r#"<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <meta name="referrer" content="no-referrer">
    <meta name="meander-app-link" content="__APP_LINK__">

    <meta property="og:type" content="article">
    <meta property="og:title" content="__OG_TITLE__">
    <meta property="og:description" content="__OG_DESCRIPTION__">
    <meta property="og:image" content="__AUTHOR_AVATAR__">

    <meta name="twitter:card" content="summary">
    <meta name="twitter:title" content="__OG_TITLE__">
    <meta name="twitter:description" content="__OG_DESCRIPTION__">
    <meta name="twitter:image" content="__AUTHOR_AVATAR__">

    <title>__TITLE__ | Meander</title>
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
            <img src="__AUTHOR_AVATAR__" alt="__ALT_AUTHOR_NAME__" class="avatar" referrerpolicy="no-referrer">
            <div class="author-info">
                <h2 class="author-name">__AUTHOR_NAME__</h2>
                <p class="community-label">Сообщество Meander</p>
            </div>
        </div>

        <div class="post-content">
            __CONTENT__
        </div>

        <div class="actions">
            <a href="__APP_LINK__" class="btn btn-primary">
                Читать в приложении
            </a>
            <a href="__GOOGLE_PLAY_LINK__" class="btn btn-tonal">
                Скачать Meander
            </a>
        </div>
    </div>

    <script src="/share/redirect.js"></script>
</body>
</html>"#;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/redirect.js", get(redirect_js))
        .route("/quest/{id}", get(share_quest))
        .route("/profile/{id}", get(share_profile))
        .route("/post/{id}", get(share_post))
}

async fn redirect_js() -> ApiResult {
    Ok(Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/javascript")
        .body(Body::from(REDIRECT_JS))
        .map_err(|e| ApiError::internal(e.to_string()))?)
}

async fn share_quest(State(state): State<Arc<AppState>>, Path(raw_id): Path<String>) -> ApiResult {
    let id = match Uuid::parse_str(&raw_id) {
        Ok(id) => id,
        Err(_) => return plain_text(StatusCode::NOT_FOUND, "Invalid ID"),
    };

    let row = match sqlx::query(
        "SELECT title, description, preview_image_url FROM quests
         WHERE id = $1 AND status = 'published'",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    {
        Ok(Some(row)) => row,
        Ok(None) => return plain_text(StatusCode::NOT_FOUND, "Квест не найден"),
        Err(err) => {
            tracing::error!(error = %err, "share quest error");
            return plain_text(StatusCode::INTERNAL_SERVER_ERROR, "Ошибка сервера");
        }
    };

    let title: String = row.try_get("title")?;
    let description: Option<String> = row.try_get("description")?;
    let preview_image_url: Option<String> = row.try_get("preview_image_url")?;

    let default_desc = "Увлекательный текстовый квест в Meander.".to_string();
    let description = description.unwrap_or(default_desc);
    let body_desc = truncate_node(&description);

    let default_img = format!("{}/uploads/default_cover.jpg", state.cfg.base_url);
    let image_url = sanitize_http_url(preview_image_url.as_deref().unwrap_or(""), &default_img);

    let html = render_html(
        &title,
        &body_desc,
        &image_url,
        &format!("meander://share/quest/{id}"),
        false,
    );
    html_response(StatusCode::OK, html)
}

async fn share_profile(
    State(state): State<Arc<AppState>>,
    Path(raw_id): Path<String>,
) -> ApiResult {
    let id = match Uuid::parse_str(&raw_id) {
        Ok(id) => id,
        Err(_) => return plain_text(StatusCode::NOT_FOUND, "Invalid ID"),
    };

    let row = match sqlx::query("SELECT full_name, bio, avatar_url FROM profiles WHERE id = $1")
        .bind(id)
        .fetch_optional(&state.db)
        .await
    {
        Ok(Some(row)) => row,
        Ok(None) => return plain_text(StatusCode::NOT_FOUND, "Пользователь не найден"),
        Err(err) => {
            tracing::error!(error = %err, "share profile error");
            return plain_text(StatusCode::INTERNAL_SERVER_ERROR, "Ошибка сервера");
        }
    };

    let full_name: String = row.try_get("full_name")?;
    let bio: Option<String> = row.try_get("bio")?;
    let avatar_url: Option<String> = row.try_get("avatar_url")?;

    let default_bio = "Автор и игрок в текстовые квесты Meander.".to_string();
    let description = bio.unwrap_or(default_bio);
    let body_desc = truncate_node(&description);

    let default_img = format!("{}/uploads/default_avatar.jpg", state.cfg.base_url);
    let image_url = sanitize_http_url(avatar_url.as_deref().unwrap_or(""), &default_img);

    let html = render_html(
        &full_name,
        &body_desc,
        &image_url,
        &format!("meander://share/profile/{id}"),
        true,
    );
    html_response(StatusCode::OK, html)
}

async fn share_post(State(state): State<Arc<AppState>>, Path(raw_id): Path<String>) -> ApiResult {
    let id = match Uuid::parse_str(&raw_id) {
        Ok(id) => id,
        Err(_) => return plain_text(StatusCode::NOT_FOUND, "Invalid ID"),
    };

    let row = match sqlx::query(
        "SELECT ap.content, p.full_name, p.avatar_url
         FROM author_posts ap
         JOIN profiles p ON ap.author_id = p.id
         WHERE ap.id = $1 AND ap.is_active = true",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    {
        Ok(Some(row)) => row,
        Ok(None) => return plain_text(StatusCode::NOT_FOUND, "Пост не найден"),
        Err(err) => {
            tracing::error!(error = %err, "share post error");
            return plain_text(StatusCode::INTERNAL_SERVER_ERROR, "Ошибка сервера");
        }
    };

    let content: String = row.try_get("content")?;
    let full_name: String = row.try_get("full_name")?;
    let avatar_url: Option<String> = row.try_get("avatar_url")?;

    let default_avatar = format!("{}/uploads/default_avatar.jpg", state.cfg.base_url);
    let avatar_url = sanitize_http_url(avatar_url.as_deref().unwrap_or(""), &default_avatar);

    let title = format!("Пост от {full_name}");
    let og_description = truncate_og(&content);
    let safe_content = escape_html(&content).replace('\n', "<br>");
    let safe_name = escape_html(&full_name);
    let safe_avatar = escape_html(&avatar_url);
    let safe_app_link = escape_html(&format!("meander://share/post/{id}"));
    let safe_title = escape_html(&title);

    let html = POST_HTML
        .replace("__TITLE__", &safe_title)
        .replace("__OG_TITLE__", &safe_title)
        .replace("__OG_DESCRIPTION__", &og_description)
        .replace("__AUTHOR_NAME__", &safe_name)
        .replace("__ALT_AUTHOR_NAME__", &safe_name)
        .replace("__AUTHOR_AVATAR__", &safe_avatar)
        .replace("__CONTENT__", &safe_content)
        .replace("__APP_LINK__", &safe_app_link)
        .replace("__GOOGLE_PLAY_LINK__", GOOGLE_PLAY_LINK);

    html_response(StatusCode::OK, html)
}

fn render_html(
    title: &str,
    description: &str,
    image_url: &str,
    app_link: &str,
    is_profile: bool,
) -> String {
    let safe_title = escape_html(title);
    let safe_description = escape_html(description).replace('\n', "<br>");
    let safe_og_description: String = escape_html(description)
        .chars()
        .take(150)
        .collect::<String>()
        + "...";
    let safe_image = escape_html(image_url);
    let safe_app_link = escape_html(app_link);
    let badge = if is_profile {
        "ПРОФИЛЬ"
    } else {
        "КВЕСТ"
    };
    let (img_width, img_height, img_radius) = if is_profile {
        ("120px", "120px", "50%")
    } else {
        ("100%", "200px", "20px")
    };

    QUEST_HTML
        .replace("__TITLE__", &safe_title)
        .replace("__DESCRIPTION__", &safe_description)
        .replace("__OG_DESCRIPTION__", &safe_og_description)
        .replace("__IMAGE_URL__", &safe_image)
        .replace("__APP_LINK__", &safe_app_link)
        .replace("__TYPE_BADGE__", badge)
        .replace("__IMG_WIDTH__", img_width)
        .replace("__IMG_HEIGHT__", img_height)
        .replace("__IMG_RADIUS__", img_radius)
        .replace("__GOOGLE_PLAY_LINK__", GOOGLE_PLAY_LINK)
}

fn sanitize_http_url(url: &str, fallback: &str) -> String {
    match Url::parse(url) {
        Ok(parsed) if matches!(parsed.scheme(), "http" | "https") => parsed.to_string(),
        _ => fallback.to_string(),
    }
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn truncate_og(value: &str) -> String {
    let escaped = escape_html(value);
    let truncated: String = escaped.chars().take(150).collect();
    format!("{truncated}...")
}

fn truncate_node(value: &str) -> String {
    let count = value.chars().count();
    if count > 150 {
        value.chars().take(150).collect::<String>() + "..."
    } else {
        value.to_string()
    }
}

fn plain_text(status: StatusCode, body: &'static str) -> ApiResult {
    Ok(Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
        .body(Body::from(body))
        .map_err(|e| ApiError::internal(e.to_string()))?)
}

fn html_response(status: StatusCode, body: String) -> ApiResult {
    Ok(Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
        .body(Body::from(body))
        .map_err(|e| ApiError::internal(e.to_string()))?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_html_replaces_special_characters() {
        assert_eq!(
            escape_html("<script>alert(1)</script>"),
            "&lt;script&gt;alert(1)&lt;/script&gt;"
        );
        assert_eq!(escape_html("\"Meander's"), "&quot;Meander&#39;s");
        assert_eq!(escape_html("a & b"), "a &amp; b");
    }

    #[test]
    fn sanitize_http_url_accepts_only_http_schemes() {
        assert_eq!(
            sanitize_http_url("https://example.com/img.png", "fallback"),
            "https://example.com/img.png"
        );
        assert_eq!(
            sanitize_http_url("javascript:alert(1)", "fallback"),
            "fallback"
        );
    }

    #[test]
    fn truncate_og_appends_ellipsis() {
        let short = "Hello";
        assert_eq!(truncate_og(short), "Hello...");
    }
}
