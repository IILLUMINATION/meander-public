# Backend parity harness

Differential check between the Node reference (`backend/`) and the Rust port
(`crates/mnd-server`). It compares status, `Content-Type` and the normalised
body for 118 requests: reads across every route module plus validation and
method errors that return before a commit.

The script signs its own HS256 JWTs, so it does not need `backend/node_modules`
to create tokens.

## 1. Clone the database

Use two disposable databases with identical contents. A logical dump works
even when the source has active connections:

```bash
export PATH=/tmp/pgsys/usr/bin:$PATH   # local Postgres used during porting
export LD_LIBRARY_PATH=/tmp/pgsys/usr/lib

createdb -h 127.0.0.1 -U postgres meander_parity_node
createdb -h 127.0.0.1 -U postgres meander_parity_rust
pg_dump -h 127.0.0.1 -U postgres --no-owner --no-privileges meander_dev \
  | psql -q -h 127.0.0.1 -U postgres -d meander_parity_node
pg_dump -h 127.0.0.1 -U postgres --no-owner --no-privileges meander_dev \
  | psql -q -h 127.0.0.1 -U postgres -d meander_parity_rust
```

`createdb -T meander_dev <target>` is faster, but fails while `meander_dev` has
active connections.

## 2. Start both servers

Always set `TZ=UTC` on both. The host timezone is MSK; timestamps and daily
limits otherwise differ for reasons unrelated to the port.

```bash
# Terminal 1 — Node reference
cd backend
TZ=UTC PORT=3200 BASE_URL=http://127.0.0.1:3200 \
DATABASE_URL=postgres://postgres@127.0.0.1:5432/meander_parity_node \
JWT_SECRET=smoke-secret NODE_ENV=development \
GOOGLE_CLIENT_ID=dummy GOOGLE_CLIENT_SECRET=dummy \
YANDEX_CLIENT_ID=dummy YANDEX_CLIENT_SECRET=dummy \
node dist/app.js

# Terminal 2 — Rust port
cd ..
cargo build -p mnd-server
TZ=UTC PORT=3300 BASE_URL=http://127.0.0.1:3300 \
DATABASE_URL=postgres://postgres@127.0.0.1:5432/meander_parity_rust \
JWT_SECRET=smoke-secret NODE_ENV=development \
RUST_LOG=warn ./target/debug/mnd-server
```

Do not set `ACCESS_LOG` or `DISABLE_CRON` during a parity run. The defaults are
what production uses; the canary flags are tested separately.

## 3. Run

```bash
python3 scripts/parity/parity.py \
  --node http://127.0.0.1:3200 \
  --rust http://127.0.0.1:3300 \
  --secret smoke-secret
```

Expected result:

```text
116/118 matched; 2 generated-id diffs accepted
```

The two accepted diffs are `/api/forums/quest/:questId` and
`/api/messages/system`: both create a row with a random UUID on first read.
The harness compares their shape after replacing UUIDs. Every other response,
including Russian error strings, must match exactly.

## IDs

The defaults match the local development seed:

| Argument | Default |
|---|---|
| `--user` | `11111111-1111-4111-8111-111111111111` |
| `--author` | `22222222-2222-4222-8222-222222222222` |
| `--admin` | `33333333-3333-4333-8333-333333333333` |
| `--quest` | `aaaaaaaa-1111-4111-8111-111111111111` |
| `--quest2` | `bbbbbbbb-1111-4111-8111-111111111111` |
| `--quest3` | `cccccccc-1111-4111-8111-111111111111` |
| `--post` | `dddddddd-1111-4111-8111-111111111111` |

If a clone uses different rows, pass the matching IDs explicitly.

## Normalisation

- Server ports in URLs are replaced with `HOST` so `download_url`/`file_url`
  can be compared.
- `last_seen_at`, `peer_last_seen_at`, `online_at`, `last_active_at`,
  `viewed_at`, `server_time` and `now` are considered volatile.
- HTML whitespace is collapsed. The shared-profile template is otherwise
  byte-identical.
- JSON object keys are sorted; array order is significant.

## Known non-diffs

- `POST /api/messages/system/broadcast` is intentionally not covered: Node
  returns 500 because its `INSERT … SELECT` declares an unused `$2`, while Rust
  returns 200. This is documented in `crates/mnd-server/PORTING.md`.
- `/uploads` is served by `ServeDir` and has no ETag; Express `static` adds one.
  This is a deliberate deviation documented in `PORTING.md`.
- Cross-database comparisons never compare generated UUIDs or random IDs.