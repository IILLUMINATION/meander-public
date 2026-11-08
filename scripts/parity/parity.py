#!/usr/bin/env python3
"""Differential smoke for the Node and Rust backends.

The two servers must point at identical database clones. The script signs JWTs
itself, so it needs no Node dependencies. It checks status, content type and
normalised body for a broad read-only set plus validation/method errors that
return before any commit.

Usage:
    python3 scripts/parity/parity.py \
        --node http://127.0.0.1:3200 --rust http://127.0.0.1:3300 \
        --secret "$JWT_SECRET"
"""
import argparse
import base64
import hashlib
import hmac
import json
import re
import sys
import time
import urllib.error
import urllib.request

# IDs from the local seed used during development. Override them when the
# database clone uses different rows.
DEFAULT_USER = "11111111-1111-4111-8111-111111111111"
DEFAULT_AUTHOR = "22222222-2222-4222-8222-222222222222"
DEFAULT_ADMIN = "33333333-3333-4333-8333-333333333333"
DEFAULT_QUEST = "aaaaaaaa-1111-4111-8111-111111111111"
DEFAULT_QUEST2 = "bbbbbbbb-1111-4111-8111-111111111111"
DEFAULT_QUEST3 = "cccccccc-1111-4111-8111-111111111111"
DEFAULT_POST = "dddddddd-1111-4111-8111-111111111111"

# Handlers that create a row on first read. Their UUID cannot match across
# isolated databases; shape and slug are still compared.
GENERATED_ID_PATHS = {
    "/api/forums/quest/",
    "/api/messages/system",
}

VOLATILE_KEYS = {
    "last_seen_at",
    "peer_last_seen_at",
    "online_at",
    "last_active_at",
    "viewed_at",
    "server_time",
    "now",
}
UUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I
)


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_token(secret, user_id, role, ttl=7 * 24 * 3600):
    header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64(
        json.dumps(
            {"id": user_id, "role": role, "tv": 0, "exp": int(time.time()) + ttl},
            separators=(",", ":"),
        ).encode()
    )
    signing = f"{header}.{payload}".encode()
    sig = b64(hmac.new(secret.encode(), signing, hashlib.sha256).digest())
    return f"{header}.{payload}.{sig}"


def normalise(value, key=None):
    if key in VOLATILE_KEYS:
        return "<volatile>"
    if isinstance(value, dict):
        return {k: normalise(v, k) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [normalise(v) for v in value]
    if isinstance(value, str):
        value = value.replace("127.0.0.1:3200", "HOST").replace("127.0.0.1:3300", "HOST")
        value = value.replace("http://localhost:3200", "HOST").replace(
            "http://localhost:3300", "HOST"
        )
    return value


def body_norm(content_type, raw):
    text = raw.decode("utf-8", "replace")
    if "json" in content_type:
        try:
            return normalise(json.loads(text))
        except Exception:
            return text
    if "html" in content_type:
        text = re.sub(r"\s+", " ", text).strip()
    return normalise(text)


def fetch(base, method, path, headers, body=None):
    req = urllib.request.Request(base + path, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return response.status, response.headers.get("content-type", ""), response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.headers.get("content-type", ""), error.read()


def get_cases(q, q2, q3, user, author, post):
    return [
        ("/", None),
        ("/robots.txt", None),
        ("/.well-known/security.txt", None),
        ("/quests", None),
        ("/quests?limit=2&offset=0", None),
        ("/quests?sort=downloads", None),
        ("/quests?genre=quest", None),
        ("/quests/featured", None),
        ("/quests/genres", None),
        ("/quests/liked-genres", "user"),
        ("/quests/liked-genres", None),
        ("/quests/activity/recent", None),
        (f"/quests/{q}", None),
        (f"/quests/{q}/reviews", None),
        (f"/quests/{q}/screenshots", None),
        (f"/quests/{q}/my-vote", None),
        (f"/quests/{q}/my-vote", "user"),
        (f"/quests/{q}/my-review", None),
        (f"/quests/{q}/my-review", "user"),
        (f"/quests/{q}/analytics", None),
        (f"/quests/{q}/analytics", "admin"),
        ("/quests/analytics/author", "user"),
        (f"/quests/{q2}", None),
        (f"/quests/{q3}", None),
        (f"/profiles/{user}", None),
        (f"/profiles/{author}", None),
        (f"/profiles/{user}/quests", None),
        (f"/profiles/{user}/reviews", None),
        (f"/profiles/{user}/is-following", None),
        (f"/profiles/{user}/is-following", "user"),
        (f"/profiles/{user}/playhistory", None),
        (f"/profiles/{user}/achievements", None),
        ("/profiles/me/playhistory", "user"),
        ("/profiles/me/rewards", "user"),
        ("/profiles/sync-settings", "user"),
        ("/profiles/author-notifs-settings", "user"),
        ("/profiles/cosmetics/mine", "user"),
        (f"/share/quest/{q}", None),
        (f"/share/profile/{user}", None),
        (f"/share/post/{post}", None),
        ("/share/redirect.js", None),
        ("/music", None),
        ("/music?limit=1", None),
        ("/assets", None),
        ("/assets?limit=1", None),
        ("/api/community/online", None),
        ("/api/community/top", None),
        ("/api/community/feed", None),
        (f"/api/community/post/{post}", None),
        ("/api/forums", None),
        (f"/api/forums/quest/{q}", None),
        ("/api/forums/topics/hot", None),
        (f"/api/author-walls/{user}/posts", None),
        (f"/api/author-walls/posts/{post}", None),
        (f"/api/author-walls/posts/{post}/comments", None),
        ("/api/app/partner-banners", None),
        ("/api/app/version/check", None),
        ("/api/messages/threads", "user"),
        (f"/api/messages/threads/peer/{user}", "user"),
        ("/api/messages/privacy", "user"),
        ("/api/messages/blocks", "user"),
        ("/api/messages/system", "user"),
        ("/notifications", "user"),
        ("/notifications/unread-count", "user"),
        ("/reports/admin", "admin"),
        ("/admin/stats", "admin"),
        ("/admin/activity", "admin"),
        ("/admin/moderation-queue", "admin"),
        ("/admin/music-moderation-queue", "admin"),
        ("/admin/assets-moderation-queue", "admin"),
        ("/admin/blocked-users", "admin"),
        ("/admin/cosmetics/catalog", "admin"),
        ("/admin/cosmetics/grants", "admin"),
        ("/admin/cosmetics/users", "admin"),
        ("/admin/cosmetics/codes", "admin"),
        ("/cloud-sync/quota", "user"),
        ("/cloud-sync/quests", "user"),
        ("/auth/account", "user"),
        ("/profiles/me", None),
        (f"/static/downloads/{q}.mnd", None),
        ("/static/downloads/not-a-uuid.mnd", None),
        ("/uploads/nope.png", None),
        ("/does-not-exist", None),
    ]


def validation_cases(q):
    return [
        ("HEAD", "/", None, None),
        ("HEAD", "/quests", None, None),
        ("PUT", "/quests", None, b"{}"),
        ("GET", "/profiles", None, None),
        ("POST", "/quests", None, b"{}"),
        ("POST", "/quests", "user", b"{}"),
        ("POST", "/quests", "user", b"{bad"),
        ("DELETE", f"/quests/{q}", None, None),
        ("POST", f"/quests/{q}/vote", None, b"{}"),
        ("POST", f"/quests/{q}/vote", "user", b'{"value":99}'),
        ("POST", "/quests/not-a-uuid/vote", "user", b'{"value":1}'),
        ("POST", "/auth/google/token", None, b"{}"),
        ("POST", "/auth/google/exchange", None, b"{}"),
        ("DELETE", "/auth/account", "user", b"{}"),
        ("DELETE", "/auth/account", "user", b'{"acknowledged":false}'),
        ("DELETE", "/auth/account", "user", b'{"acknowledged":true,"reason":"x"*600}'),
        ("POST", "/auth/account/restore", "user", b"{}"),
        ("POST", "/reports", None, b"{}"),
        ("POST", "/notifications/not-a-uuid/read", "user", b"{}"),
        ("PATCH", "/profiles/not-a-uuid", "user", b"{}"),
        ("POST", "/profiles/update-streak", None, b"{}"),
        ("POST", "/profiles/redeem", "user", b"{}"),
        ("POST", "/api/messages/threads/not-a-uuid", "user", b"{}"),
        ("GET", "/api/messages/threads/not-a-uuid", "user", None),
        ("POST", "/api/forums", "user", b"{}"),
        ("POST", "/api/forums", "user", b'{"name":"x"}'),
        ("POST", "/api/author-walls/not-a-uuid/posts", "user", b"{}"),
        ("POST", "/api/app/version/check", None, None),
        ("GET", "/admin/stats", "user", None),
        ("GET", "/admin/stats", None, None),
        ("POST", "/cloud-sync/quests/not-a-uuid/check", "user", b"{}"),
        ("DELETE", "/cloud-sync/quests/not-a-uuid", "user", None),
        ("POST", "/music/not-a-uuid/vote", "user", b'{"value":99}'),
        ("POST", "/assets/not-a-uuid/vote", "user", b'{"value":99}'),
        ("POST", "/share/quest/not-a-uuid", None, b"{}"),
    ]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", default="http://127.0.0.1:3200")
    parser.add_argument("--rust", default="http://127.0.0.1:3300")
    parser.add_argument("--secret", default="smoke-secret")
    parser.add_argument("--user", default=DEFAULT_USER)
    parser.add_argument("--author", default=DEFAULT_AUTHOR)
    parser.add_argument("--admin", default=DEFAULT_ADMIN)
    parser.add_argument("--quest", default=DEFAULT_QUEST)
    parser.add_argument("--quest2", default=DEFAULT_QUEST2)
    parser.add_argument("--quest3", default=DEFAULT_QUEST3)
    parser.add_argument("--post", default=DEFAULT_POST)
    args = parser.parse_args()

    tokens = {
        "user": make_token(args.secret, args.user, "user"),
        "admin": make_token(args.secret, args.admin, "admin"),
    }

    def request_headers(auth, body):
        headers = {"Accept": "application/json, text/plain, */*"}
        if auth:
            headers["Authorization"] = "Bearer " + tokens[auth]
        if body is not None:
            headers["Content-Type"] = "application/json"
        return headers

    total = 0
    failures = 0
    explained = 0

    def check(method, path, auth, body, allow_generated_id=False):
        nonlocal total, failures, explained
        total += 1
        node = fetch(args.node, method, path, request_headers(auth, body), body)
        rust = fetch(args.rust, method, path, request_headers(auth, body), body)
        problems = []
        if node[0] != rust[0]:
            problems.append(f"status {node[0]} != {rust[0]}")
        if node[1] != rust[1]:
            problems.append(f"content-type {node[1]!r} != {rust[1]!r}")
        node_body = body_norm(node[1], node[2])
        rust_body = body_norm(rust[1], rust[2])
        if node_body != rust_body:
            if allow_generated_id:
                strip = lambda value: UUID_RE.sub("UUID", json.dumps(value, sort_keys=True))
                if strip(node_body) == strip(rust_body):
                    explained += 1
                    print(f"OK   {method:6} {auth or 'guest':5} {path} (generated UUID)")
                    return
            problems.append("body differs")
        if problems:
            failures += 1
            print(f"FAIL {method:6} {auth or 'guest':5} {path}: {'; '.join(problems)}")
            print("  NODE:", repr(node_body)[:500])
            print("  RUST:", repr(rust_body)[:500])
        else:
            print(f"OK   {method:6} {auth or 'guest':5} {path}")

    for path, auth in get_cases(args.quest, args.quest2, args.quest3, args.user, args.author, args.post):
        check("GET", path, auth, None, allow_generated_id=any(path.startswith(p) for p in GENERATED_ID_PATHS))
    for method, path, auth, body in validation_cases(args.quest):
        check(method, path, auth, body)

    print(f"\n{total - failures}/{total} matched; {explained} generated-id diffs accepted")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())