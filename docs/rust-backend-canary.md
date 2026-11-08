# Rust backend canary — safe rollout

Node remains the source of truth and the rollback target until the canary is
finished. Merging code does **not** mean switching traffic.

## Invariants

- Both processes use the **same** `DATABASE_URL`, `JWT_SECRET`, `BASE_URL`,
  `PUBLIC_DIR`, `CORS_ORIGINS` and `QUEST_XACCEL_*` values.
- `BASE_URL` must stay the public production URL. If it points at the canary
  port, Rust-generated `download_url`/share links differ from Node.
- Only one process owns background jobs.
- Socket.IO is not split between Node and Rust while their rooms are
  in-memory: route `/socket.io/` to one backend.
- No automatic retry of mutating requests. A timeout can happen after the
  handler committed; replaying it can duplicate writes.

## Environment for the canary process

```dotenv
PORT=3100
DISABLE_CRON=1
ACCESS_LOG=1
# Same values as Node:
DATABASE_URL=...
JWT_SECRET=...
BASE_URL=https://backend.meander.sbs
PUBLIC_DIR=/var/www/mnd/backend/public
CORS_ORIGINS=...
```

`DISABLE_CRON=1` is required while Node still runs the achievement, cloud
cleanup, account-deletion, cosmetics and reward sweeps.

`ACCESS_LOG=1` emits one structured line per HTTP request:

```text
target=mnd_server::access request_id=... upstream=rust method=GET path=/quests
status=200 latency_ms=17 client_ip=... request
```

It also returns `X-Request-Id`, so nginx's `$request_id` can be correlated with
the Rust line. Do not enable it on both backends until Node has the same
middleware; the canary process is enough.

## Stages

| Stage | Traffic | Routes | Socket.IO | Gate |
|---|---|---|---|---|
| 0. Deploy idle | 0% | none | Node | Process starts, `/` = 204, same DB |
| 1. Shadow | 0% | GET/HEAD mirrored | Node | 24h, response diffs reviewed |
| 2. Read canary | 1% of users | GET/HEAD | Node | 24h: 5xx/p95 not worse than Node |
| 3. Read canary | 5% then 10% | GET/HEAD | Node | 24–48h per step |
| 4. Write canary | 1% | POST/PUT/PATCH/DELETE | see below | Explicit idempotency review |
| 5. Read majority | 50% of users | GET/HEAD | Node | 24–48h |
| 6. Cutover | 100% | all | Rust | Low-traffic window, Node standby |

Do not start at 50%. Do not enable write retries in any stage.

### WebSocket decision

There are two safe choices during a split:

1. **Read-only canary:** all `/socket.io/` traffic stays on Node. Rust handles
   GET/HEAD only. This is the recommended first rollout.
2. **Full realtime cutover:** all HTTP and all WebSocket traffic move to Rust
   together in a low-traffic window. Node stays deployed but idle.

A 50/50 split of WebSocket traffic without a shared adapter loses events
between users on different backends. Do not do it.

## Fallback policy

- `GET`/`HEAD`: nginx may retry the other upstream on connection error or
  timeout.
- `POST`/`PUT`/`PATCH`/`DELETE`: no automatic retry. Return the error to the
  client. If a fallback is unavoidable, add an idempotency key first and store
  `(key, request hash, result)`; old clients do not send it, so it does not
  help the first canary.
- Circuit breaker: if the Rust error rate crosses the threshold, stop sending
  **new** requests to it and leave in-flight requests alone.

## Monitoring

Alert on:

- Rust 5xx rate > 1% over 5 minutes, or > 2× Node's rate
- p95 latency > Node's p95 + 50 ms
- `429` spike (rate limits are per process, not shared)
- DB pool exhaustion / `too many connections`
- WebSocket disconnect/reconnect spike
- duplicate notification or cron side effects
- client Sentry/crash reports after mirror switch

Keep logs rotated. `pm2` logs without rotation can fill the disk; use
`pm2-logrotate` or file logging with rotation. Never log `Authorization`,
JWTs, passwords, request bodies, email or phone numbers.

## Rollback

1. Switch nginx upstream back to Node (one reload, no DB migration involved).
2. Keep the Rust process running for log collection, then stop it.
3. Leave the database untouched; Node uses the same schema.
4. Verify `/`, login, catalog, DM and a file download.

## Local smoke before deploying

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

Run the differential harness against disposable database clones as described in
[`scripts/parity/README.md`](../scripts/parity/README.md). Then run the canary process with `DISABLE_CRON=1 ACCESS_LOG=1` and check that
`GET /` returns 204 and no background job logs appear.