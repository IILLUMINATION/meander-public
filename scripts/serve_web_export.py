#!/usr/bin/env python3
"""Локальная раздача веб-экспорта квеста.

    python3 scripts/serve_web_export.py --dir dist/web --port 8000
    # http://127.0.0.1:8000/<папка-квеста>/

Wasm-движок поднимает worker pool через SharedArrayBuffer, а он доступен
только в cross-origin isolated окружении. Без заголовков COOP/COEP страница
открывается, но движок падает с `RuntimeError: unreachable`. Обычный
`python -m http.server` этих заголовков не ставит — поэтому этот скрипт.

Заголовки нужны и на проде: nginx `add_header`, Netlify `_headers`,
Cloudflare Transform Rules. Хостинги без управления заголовками (например,
GitHub Pages) веб-плеер не запустят.
"""

import argparse
import http.server
import os
import sys


class _Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def guess_type(self, path):
        if path.endswith(".wasm"):
            return "application/wasm"
        if path.endswith(".mnd"):
            return "application/octet-stream"
        return super().guess_type(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", default=".", help="папка с экспортом")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--bind", default="127.0.0.1")
    args = parser.parse_args()

    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        print(f"Нет папки: {root}", file=sys.stderr)
        return 1

    handler = lambda *a, **kw: _Handler(*a, directory=root, **kw)
    with http.server.ThreadingHTTPServer((args.bind, args.port), handler) as srv:
        print(f"Раздаю {root}")
        print(f"http://{args.bind}:{args.port}/  (COOP/COEP включены)")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())