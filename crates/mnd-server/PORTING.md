# Porting the Node backend to Rust — contract

The Rust server lives in `crates/mnd-server` and must be a **drop-in replacement**
for `backend/src`: same paths, methods, status codes, JSON field names and error
strings. The Flutter apps and web players are already shipped and cannot be
changed, so behavioural parity is the acceptance criterion — not "a nicer API".

## Ground rules

- Port **only** the files assigned to you. Do not touch `backend/` (the reference
  implementation), other agents' modules, `lib.rs`, `routes/mod.rs`, or
  `Cargo.toml`.
- No `unwrap()`/`expect()`/`panic!()` on request-derived data; map errors with
  `?` into `ApiError`. `expect()` is fine for `LazyLock` regex initialisation.
- Do not add dependencies. Everything needed is already in `Cargo.toml`
  (`sqlx`, `axum`, `serde_json`, `reqwest`, `jsonwebtoken`, `bcrypt`, `sha2`,
  `hmac`, `hex`, `base64`, `uuid`, `chrono`, `rand`, `regex`, `mime_guess`,
  `tokio`, `futures`). If something is genuinely missing, stop and report it.
- Use **runtime** `sqlx::query` / `sqlx::query_scalar` with `.bind(...)`; never
  `query!` macros (there is no compile-time database).
- Bind `Uuid`, `Option<Uuid>`, `i32`, `i64`, `bool`, `&str`, `Option<&str>`,
  `chrono::DateTime<Utc>`, `serde_json::Value` directly. For arrays use
  `&Vec<Uuid>` / `&Vec<String>`.
- Every handler returns `ApiResult` (`Result<Response, ApiError>`) and ends in
  `Ok(Json(value).into_response())` or a helper from `crate::error`.
- SQL errors: use `?` to get `ApiError` (it reproduces `humanErrorMiddleware`).
- Node status codes are part of the contract: 400/401/403/404/409/413/415/429/500
  exactly as in the TypeScript.

## What exists already (use it, don't re-implement)

```rust
use crate::state::AppState;              // Arc<AppState>: cfg, db, http, limiter, accounts, io
use crate::error::{ApiError, ApiResult, ok_json, ok_created, no_content, missing_field, payload_too_large};
use crate::json::{ts, opt_ts, pg_row_to_json, rows_to_json, parse_int, parse_num, parse_uuid, truthy};
use crate::auth::{AuthUser, OptionalAuth, AdminUser};  // extractors
use crate::middleware::{ClientIp, upload_allowed};
use crate::extractors::{Body, FormData, UploadedFile, collect_multipart};
```

Handler shape:

```rust
pub async fn handler(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(id): Path<Uuid>,
    Query(q): Query<HashMap<String, String>>,
    Body(body): Body,
) -> ApiResult { … }
```

Extractor order matters only for `Body`/`Multipart` (they consume the body and
must be last). `AuthUser` rejects exactly like `authMiddleware`; `AdminUser`
rejects like `adminAuth`.

`OptionalAuth` / `AuthUser` expose `id: Uuid` and `role`. Use the database for
authorisation decisions (`services::visibility::{is_admin, is_staff,
can_see_unpublished}`), never the token role.

`Body` returns a JSON object for `application/json`, form-urlencoded and empty
bodies. Use `body.str("x")`, `body.i64("x")`, `body.bool("x")`, `body.array("x")`,
`body.0` for the raw `Value`.

Multipart routes: `collect_multipart(multipart, max_file_bytes).await?` returns
`FormData { fields, files }`; files are streamed to temp paths (dropped
automatically). `form.str("x")`, `form.value("x")` (JSON-decoded),
`form.file("field")`. Do not buffer whole uploads in memory.

Response JSON: for raw rows use `rows_to_json(&rows)` / `pg_row_to_json(&row)` —
they reproduce node-postgres types (bigint/numeric as strings, timestamps as
`Date.toISOString()` with milliseconds). For hand-built objects use `json!`.

Sockets: `state.emit_to_user(&user_id.to_string(), "new_notification", payload)`.
Notifications: `services::notifications::create_notification(&state,
NewNotification { user_id, actor_id, kind, quest_id, review_id, payload }).await`.
Inside a transaction use `create_notification_tx(&state, &mut *tx, …)`.

Transactions: `let mut tx = state.db.begin().await?; …; tx.commit().await?;`.

## Shared-service API contract

Owners implement these exact signatures; callers code against them.

`services::cosmetics` (owner: profiles task)
```rust
pub const COSMETIC_SLOTS: [&str; 5];
pub fn is_free_cosmetic(id: &str) -> bool;
pub fn cosmetic_slot(id: &str) -> Option<&'static str>;
pub fn validate_equipped(value: &serde_json::Value) -> Result<serde_json::Map<String, serde_json::Value>, String>;
pub fn sanitize_stored(raw: &serde_json::Value) -> serde_json::Map<String, serde_json::Value>;
pub async fn find_missing_grants(state: &AppState, user_id: Uuid, ids: &[String]) -> Vec<String>;
pub async fn equipped_for(state: &AppState, user_id: Uuid) -> serde_json::Map<String, serde_json::Value>;
pub async fn list_grants(state: &AppState, user_id: Uuid) -> Vec<serde_json::Value>;
pub struct GrantOptions { pub days: Option<i32>, pub source: String, pub reason: Option<String>, pub granted_by: Option<Uuid> }
pub async fn grant_cosmetics(state: &AppState, user_id: Uuid, ids: &[String], opts: GrantOptions) -> (Vec<String>, Vec<String>); // (granted, skipped)
pub fn legacy_banner_style(equipped: &serde_json::Map<String, serde_json::Value>) -> Option<serde_json::Value>;
pub async fn sweep_expired_cosmetics(state: &AppState) -> u64;
```

`services::rewards` (owner: profiles task)
```rust
pub async fn grant_due_rewards(state: &AppState, user_id: Uuid) -> Vec<String>;
pub async fn sweep_reward_ladder(state: &AppState) -> u64;
pub async fn reward_progress(state: &AppState, user_id: Uuid) -> serde_json::Value; // array
pub async fn read_metrics(state: &AppState, user_id: Uuid) -> serde_json::Value;    // {streak, game_days, reviews, downloads}
```

`services::cloud_sync_tier` (owner: cloud-sync task)
```rust
pub async fn recompute_tier(state: &AppState, user_id: Uuid) -> Result<String, ApiError>;
pub async fn grant_tier(state: &AppState, user_id: Uuid, tier: &str, days: Option<i32>, source: &str) -> Result<(), ApiError>;
pub async fn build_upgrade_hints(state: &AppState, user_id: Uuid) -> serde_json::Value;
pub struct TierConfig { pub name: &'static str, pub max_file_bytes: u64, pub max_files: i64, pub max_total_bytes: u64, /* … */ }
pub fn tier_config(name: &str) -> &'static TierConfig;
pub async fn effective_tier(state: &AppState, user_id: Uuid) -> String;
```

`services::activity` (owner: admin task)
```rust
pub async fn get_activity_overview(state: &AppState, days: Option<i64>) -> serde_json::Value;
```
(the existing `touch_daily_activity` stays.)

`services::account_deletion` (owner: profiles task)
```rust
pub async fn run_account_deletion_sweep(state: &std::sync::Arc<AppState>) -> serde_json::Value;
```

## Route modules and the Node references

`routes/mod.rs` already declares every module; `lib.rs` already nests the
prefixes. Implement `pub fn router() -> Router<Arc<AppState>>` with the same
relative paths as the Node router.

| Rust file | Node source |
| --- | --- |
| `routes/quests.rs` (+ services `market_query`, `quest_scan`, `publish_errors`, `quest_analytics`, `github`) | `routes/quests.ts` |
| `routes/auth.rs` (+ `services/google_exchange`, `telegram_jwt`) | `routes/auth.ts`, `auth_yandex.ts`, `auth_telegram.ts`, `auth_apple.ts` |
| `routes/profiles.rs` (+ `services/cosmetics`, `rewards`, `sync_settings_crypto`, `account_deletion`) | `routes/profiles.ts` |
| `routes/admin.rs` (+ `services/activity` dashboard) | `routes/admin.ts` |
| `routes/share.rs`, `routes/reports.rs`, `routes/community.rs` | same names |
| `routes/cloud_sync.rs` (+ `services/cloud_sync_storage`, `cloud_sync_tier`, `cloud_sync_cleanup`) | `routes/cloud_sync.ts` |
| `routes/music.rs`, `routes/assets.rs` | same names |
| `routes/messages.rs`, `routes/notifications.rs` | same names |
| `routes/forums.rs` | `routes/forums.ts` |
| `routes/author_wall.rs` | `routes/author-wall.ts` |

Details that are easy to miss:

- Route parameters use axum 0.8 syntax `{id}`. Express `:id` maps to it.
- `router.route("/", get(x).post(y))` for the collection path; the mount prefix
  is added by `lib.rs` (e.g. `/api/author-walls`).
- Where Node mounted middleware inside a router (e.g. `authMiddleware` on one
  route only), attach it per method route with `.route_layer(...)` or take the
  extractor in that handler. Taking the extractor is preferred.
- Upload limits: `multer` caps are per file (100 MB regular, 500 MB verified
  quests). Pass the cap to `collect_multipart` **and** raise the axum body
  limit on that router — the app-wide `DefaultBodyLimit` is 1 MB, and
  `Multipart` obeys it:
  `Router::new()... .layer(DefaultBodyLimit::max(500 * 1024 * 1024))`.
- `res.status(x).send({error})` → `ApiError::new(StatusCode::X, "...")`.
- `res.sendStatus(204)` → `no_content()`.
- Empty JSON bodies from Express are `{}` — use `Body`'s accessors.
- Node timestamps in hand-built JSON must use `ts(...)`; `pg_row_to_json`
  already does it for rows.
- Do not "improve" texts, field names or statuses. Copy them verbatim
  (including Russian text and emoji).

## Verification you must run

1. `cargo check -p mnd-server 2>&1 | grep -E "^error" -A6` and fix every error
   that points at **your** files. Errors in other files are other agents'
   in-flight work — ignore them. Cargo may wait on the lock; that is expected.
2. Add `#[cfg(test)]` unit tests only for pure logic you introduced (query
   parsing, validation, formatting). Do not add tests that need a database.
3. A local dev database is available for reading schema:
   `PATH=/tmp/pgsys/usr/bin:$PATH psql -h 127.0.0.1 -U postgres -d meander_dev -c '\\d+ quests'`
   It is a **local** cluster only; never connect anywhere else.
4. Report: files changed, endpoints covered, deviations from Node, anything
   still missing.
## Cross-cutting findings (verified against the local cluster)

### Enum columns need explicit parameter casts

`quests.status` is `quest_status` and `reviews.status` is `review_status`.
node-postgres sends parameters untyped, so Postgres infers the enum and
`INSERT ... status = $11` works. sqlx always sends an explicit `TEXT` type, so
the same statement fails with *"column status is of type quest_status but
expression is of type text"*. Cast every bound status:

```sql
INSERT INTO quests (... status ...) VALUES (..., $11::quest_status, ...)
UPDATE quests SET status = $1::quest_status WHERE id = $2
```

Literal values (`status = 'approved'`) need no cast. This applies to every
enum column in every ported module, not just quests.

### Local cluster schema gaps (do not change repo SQL)

The dev database was built from `db_schema.sql` + migrations, and a few
artefacts that production has are missing or stale there. They are **not**
backend bugs and must not be "fixed" in `backend/`:

- `quests.genres` — declared in `db_schema.sql` but the migration that adds it
  fails on a fresh database. Added locally for smoke tests.
- `market_quests` — a view created with `q.*` does not grow new columns when
  `ALTER TABLE quests ADD COLUMN is_nsfw` runs. Production's view was rebuilt
  by `migration_market_tiers.sql`; rebuild it locally before testing the
  catalogue.
- `reviews.author_reply` — referenced by analytics in the Node code and by this
  port, but no SQL file in the repository creates it. Production has it from
  outside the repo. Added locally for smoke tests.
- `author_posts` — same class of gap; routes are ported, the table is absent
  from every SQL file.

### Extractor state type

`extractors::Body` implements `FromRequest<Arc<AppState>>` (the router's state
type), not `AppState`. A handler taking `Body` therefore requires the router to
be built over `Arc<AppState>`, which `lib.rs` does.

### New dependency

`zip` (deflate only) was added for `services::quest_scan` — archive analysis
cannot be reproduced without a ZIP reader, and `mnd-core` already depends on
the same crate.

### Enum columns: reading, not just writing

sqlx enforces type compatibility when decoding, so `row.get::<String>(…)` on
an enum column panics at runtime (*"as SQL type TEXT is not compatible with
SQL type quest_status"*). Node's `pg` returns the label, so the wire format is
still a string. Two helpers in `crate::json` cover every read path:

- `pg_row_to_json` / `column_json` fall back to the raw text bytes for unknown
  types (enums, domains) and normalise `TEXT[]`-style array names to `_TEXT`.
- `json::text_col(&row, "status")` is the explicit accessor for handler code
  that compares a status (`static_files`, `music`, `assets`, `forums`,
  `quest_analytics`, `quests`).

Enum columns encountered so far: `quests.status`, `reviews.status`,
`music_tracks.status`, `market_assets.status`, `market_assets.kind` — all need
`$n::<enum>` casts on **bound** parameters (literals are fine).

### Integer widths matter too

`cloud_sync_quotas.used_quests` is `INT`, and `ratings.rating` is `INT2`;
decoding them as `i64`/`i32` fails with the same mismatch error. Match the
declared width from `migration_cloud_sync.sql` / `db_schema.sql`.

### socketioxide broadcasts are async

`socketioxide` 0.18's broadcast `emit` returns a future; dropping it (as an
expression statement does) silently sends nothing. `AppState::emit_to_user` /
`emit_to_room` spawn a task and log failures. Any new event must go through
those helpers, and payloads must be owned (`Send + 'static`).

### Additional local-cluster gaps for smoke tests

- `profiles.streak_count`, `last_activity_date`, `quiet_hours_enabled`,
  `timezone_offset` are referenced by `routes/profiles.ts` and
  `routes/community.ts` but no repo SQL creates them. Added locally.
- `profile_sync_settings` comes from `migration_sync_settings.sql`; apply it
  locally or `/profiles/sync-settings` returns a column error.
- `author_posts` / `author_post_comments` / `author_post_likes` and
  `forum_topics`-style storage are absent locally, so `/api/author-walls`,
  `/api/forums` and `/api/community/feed` cannot be exercised there. The code
  mirrors the Node queries; production-only schema is the blocker.

### Second new dependency

`aes-gcm` was added for `services::sync_settings_crypto` (AES-256-GCM with
`sha256(JWT_SECRET)` as the key, IV/tag stored separately), matching the Node
ciphertext format. Verified against ciphertext produced by the Node code.

## Integration pass (final)

### Filesystem roots follow `${__dirname}`, not `cwd`

Node's routes compute `path.join(__dirname, '../../public')`, which is always
`backend/public` whether they run under `ts-node` (source) or compiled `dist`.
The Rust port therefore defaults `PUBLIC_DIR` to `backend/public` with **no**
existence-based fallback; a cwd-dependent default silently wrote uploads to
`<repo>/public` and made `/quests/:id/file` return 404 for files under
`backend/public`.

`CLOUD_SYNC_ROOT` defaults to `<cwd>/storage/cloud_sync` exactly as
`services/cloud_sync_storage.ts` does. It is not a subdirectory of
`backend/public`.

### Telegram bot token fallback

`auth_telegram.ts` reads `TELEGRAM_BOT_TOKEN || TELOXIDE_TOKEN`; the port keeps
the same precedence in `config.rs`.

### Local-cluster schema gaps, continued

Beyond `author_posts`, the author-wall feature also stores
`author_post_comments`, `author_post_likes`, `author_post_comment_likes`,
`author_post_views`, `author_post_polls*` and the two report tables
(`author_post_reports`, `author_post_comment_reports`). None of them exist in
`bigdark.db_schema.sql` or any migration in the repository; production has
them. They were recreated locally from the queries in `routes/author-wall.ts`,
`routes/reports.ts` and `routes/admin.ts` for smoke tests only.

`reports.reported_type` is a `CHECK` constraint (`reports_reported_type_check`)
that does not include `forum` or `message` until
`backend/migrations/add_message_reports.sql` is applied. Without it, reporting
a forum post or a message returns a 500.

### Verified end to end on the local cluster

Catalogue/filters/search/tier/category, quest detail and unpublished access
matrix (guest/stranger 404, author and staff 200 on both `/static/downloads`
and `/quests/:id/file`), reviews/screenshots, votes/ratings, author and quest
analytics (403 for strangers), publish with stripped ZIP + cover upload and
served file, download counters, featured, liked genres, recent activity;
profiles (`me`, detail privacy stripping, streak, rewards, sync settings,
play history, achievements, following, avatar upload, promo redeem + double
redeem 400, playtime sync); account delete (`acknowledged` guard, 3-day grace,
duplicate 409) and restore (404 once cancelled); auth provider-token 400s;
notifications list/unread/read/archive; DMs threads/peer/send/read/mute/blocks
and system broadcast; music and assets upload → admin review approve/reject
(file removed on reject) → catalogue → stream with MIME → reviews/vote;
cloud-sync PUT/GET/LIST fingerprint check/DELETE/quota/admin grant/recompute/
cleanup; admin stats/activity/queues/cosmetics catalog/grants/grant/revoke/
codes/blocked users; reports create/list/resolve/delete; author-wall full
lifecycle; forums create/list/get/patch/join/ban/moderator/report/posts/hot
topics/quest forum/remove; share HTML for quest/profile/post; community
online/top/feed/post; Socket.IO handshake plus live `new_notification`.

## Wire details found by differential testing

The port was compared against the Node server running on the same local
database (ports 3100/3200), endpoint by endpoint. The following were wrong in
the first version and are now reproduced exactly:

### Express semantics that axum does not share by default

- **Unknown paths** answer with finalhandler's HTML page, not plain text:
  `404`, `text/html; charset=utf-8`,
  `<!DOCTYPE html>…<pre>Cannot GET /path</pre>…` (`lib::express_not_found`).
- **Method mismatches**: Express falls through to later routes and otherwise
  the same 404 page, while axum answers `405` with an empty body. A middleware
  (`middleware::method_fallthrough`) rewrites `405` to the 404 page. Paths where
  Node really has a later handler with another method keep an explicit
  `MethodRouter::fallback` (e.g. `GET /profiles/me`, which Node serves through
  `GET /profiles/:id` and therefore answers `400 Invalid ID format`).
- **JSON content type**: Express sends `application/json; charset=utf-8`;
  axum's `Json` omits the parameter. `middleware::json_charset` normalises it.
- **`Path<Uuid>` rejections** were axum plain-text 400s; the handlers now take
  `Path<String>` and answer the module's own JSON (`Invalid ID format`,
  `Некорректный идентификатор`), as the Node routes do.
- **Body parsing**: `express.json({strict:true})` accepts objects and arrays,
  maps an empty body to `{}`, and rejects `null`/scalars with
  `Bad JSON format`. `Body` and the cloud-sync JSON branch follow that.

### Multipart and upload priors

- Upload routes are reached by non-multipart requests too: express's global
  JSON parser runs first and multer then passes the body through, so the route
  answers its own “file missing” 400. `extractors::upload_form` centralises
  this: multipart is streamed, JSON is parsed (and rejected with
  `Bad JSON format`), and other requests get an empty form.
- multer error classes: `app.ts` maps `Invalid image file type`,
  `Invalid quest file type` and `Unexpected upload field` to 400; everything
  else (`Invalid music file type`, `Invalid cover type`, malformed multipart,
  `Unexpected file field`) goes through `humanErrorMiddleware` as 500 with
  `original_error`. The avatar and author-wall wrappers convert multer errors
  to 400 (wall keeps 413 for size). `error::upload_error`/`error::multer_error`
  encode those classes.
- `POST /quests` has its own five-per-hour limiter keyed by author, mounted
  before body parsing (now enforced in the handler before the size gate).
  A sixth attempt returns `429` with the Node message.
- `POST /quests` with a missing/invalid file answers
  `400 {"error": …, "code": "quest_file_required"}` after the JSON parser has
  accepted the body, and `500 Multipart: Boundary not found` when the
  multipart envelope has no boundary.

### Response data details

- `DATE` columns: `pg` builds a `Date` at *local* midnight and
  `toISOString()` shifts it to UTC. `json::date_ts` uses `chrono::Local` for
  the same result (in `Europe/Moscow`, `2026-11-08` is
  `2026-11-07T21:00:00.000Z`).
- Whole `f64`s must serialise like JS numbers (`5`, not `5.0`):
  `json::js_number` is used for analytics averages and DM privacy thresholds.
- `partner_banners.id` is text (not a UUID) and `slots` is `text[]`; decoding
  them as UUID/JSON produced `null`/`[]`.
- `grantCosmetics` propagates insert errors in Node; the Rust helper used to
  swallow them and reported grants for non-existent users. It now returns
  `Result` and callers map the failure to the route's 500 text.
- Route-level `try/catch` texts (`Vote error`, `Server error toggling follow`,
  `Server error granting cosmetics`) are reproduced for the same failures;
  these bypass `humanErrorMiddleware`, so they carry no `original_error`.
- `/api/forums/quest/...` collides with the static quest-forum route. Node
  falls through to `/:slug/...` for non-GET methods (a forum whose slug is
  literally `quest` works); the static route now has a fallback dispatching
  POST `join`/`report`/`posts` and DELETE `join` to the slug handlers.

### Share pages

The HTML is content-identical (same metadata, escaping and app link); the
only difference from Node is insignificant whitespace in template literals.

### Upload validation order and swallowed checks

The music/assets upload handlers reproduce Node's exact precedence:

- assets: file present → kind → title → blocked/limit → extension → copy/dedup;
- music: file present → blocked/limit → title → performer → license → copy/dedup.

Node wraps the blocked/count queries and the hash-dedup lookup in `try/catch`
and only logs failures (`spam check failed`, `dup check failed`); the Rust
handlers now do the same instead of turning a transient database error into a
500. Cover uploads were already best-effort on both sides.

### Path matching and percent escapes

- Express is `strict: false`: `/music/` matches `/music`, but `/music//`
  does not. `tower_http::normalize_path` was too eager (it also strips
  leading and inner slashes), so `lib::TrimExpressSlash` removes exactly one
  trailing slash and leaves leading/inner duplicates alone.
- Express routers tolerate **one** extra slash between a mount path and the
  inner route (`/quests//genres`, `/api/forums//slug`, `/profiles//id`), but
  `/quests///genres` does not match. `EXPRESS_MOUNTS` lists the mounts where
  this is observable; the same layer collapses only that single duplicate.
  `/auth`, `/api/app`, `/reports` and `/api/community` do not tolerate it and
  are intentionally absent from the list.
- Router params are percent-decoded before the handler. Malformed escapes or
  invalid UTF-8 byte sequences (`/api/forums/audit%ZZ`) answer
  `400 {"error":"Failed to decode param '<raw>'","original_error":…}`; the
  check runs in `middleware::validate_path_params` via `Router::route_layer`
  so it only fires for routes that actually matched (unknown paths stay 404).

### Body parsers

- The global `express.json`/`express.urlencoded` equivalent is
  `middleware::body_parser`; `extractors::Body` only reads the cached value.
  It parses GET/HEAD bodies too (body-parser has no method check), but skips
  requests without `Content-Length`/`Transfer-Encoding` entirely.
- Media types are compared exactly (`media_type`), not by prefix:
  `application/json-patch+json` and `application/vnd.x+json` are **not**
  parsed and reach handlers as `{}`; `application/json; charset=utf-8` is.
- Supported charsets mirror `body-parser`/`iconv-lite`: `utf-8` (case
  insensitive), `utf-16`, `utf-16le`, `utf-16be` (BOM honoured); anything else
  returns `415 {"error":"unsupported charset \"<UPPER>\"", …}` before auth.
  UTF-16 bodies are decoded (`lib::decode_body`), and cloud-sync JSON uses the
  cached parsed body instead of re-reading raw bytes.
- Multipart media types: multer engages busboy for any `multipart/*` and
  busboy rejects everything but `multipart/form-data`
  (`Unsupported content type: <header>`); a missing boundary is
  `Multipart: Boundary not found`, an empty `boundary=` is skipped like
  multer, and malformed envelopes are `Unexpected end of form`.
  `POST /profiles/me/avatar` with a second file answers `Too many files`
  (multer's `single()` message), while `fields()` uploads keep
  `Unexpected file field`.

### Response headers

- Helmet defaults are copied in full: CSP includes `base-uri`, `form-action`,
  `frame-ancestors`, `object-src`, `script-src-attr` and
  `upgrade-insecure-requests`; HSTS is `max-age=31536000`; Origin-Agent-Cluster
  is `?1`. finalhandler 404 responses carry `default-src 'none'`
  (`lib::ExpressFinalHandler` marker checked by `security_headers`).
- CORS always varies on `Origin` (merged into the existing `Vary` list),
  advertises `GET,POST,PUT,PATCH,DELETE` and the configured
  `Content-Type,Authorization` list on preflight only — not on ordinary
  responses. Prefer `Origin` first in the combined `Vary` value.
- Rate limits: route-level limiters overwrite the general limiter's headers
  (`middleware::rate_headers` keeps the first set), `RateLimit-Policy:
  <max>;w=<window>` is emitted, and 429 responses also carry `Retry-After`.
- Compression matches Node's `compression` package: 1 KiB threshold and
  gzip/deflate/brotli negotiation (zstd is not enabled, as in Node).

### Known deviation

- Node's Express sets a weak `ETag` on `res.send`/`res.json` and answers
  `If-None-Match` with `304`. The Rust port does not emit ETags on JSON
  responses, so caching revalidates instead of returning 304; payloads,
  statuses and content types are otherwise identical. File downloads that
  Node serves through `res.sendFile` (`/static/downloads/:file`,
  `/quests/:id/file`, `/music/:id/file`, `/assets/:id/file`) *do* reproduce
  sendFile's `ETag`, `Last-Modified`, `Accept-Ranges` and byte-range/304/416
  behaviour. Files under `/uploads` are still served by `ServeDir`, which
  does not emit the ETag Express `static` would.
- `POST /api/messages/system/broadcast`: Node answers 500
  `{"error":"Не удалось опубликовать новость"}` because its notifications
  INSERT selects `$1::uuid` while also declaring an unused `$2`, and
  node-postgres sends untyped parameters (PostgreSQL 42P18). Rust binds typed
  parameters, so the same request succeeds with `{"success":true,"delivered":N}`.
  This is a Node defect, not a Rust deviation; the working implementation is
  kept.
