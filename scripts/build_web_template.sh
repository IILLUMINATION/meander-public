#!/usr/bin/env bash
# Собирает веб-оболочку плеера и кладёт её архивом в assets приложения —
# из него кнопка «Собрать веб-версию» достаёт готовый сайт без сети и SDK.
#
# Запускать после правок apps/web_player. CI делает то же самое перед сборкой
# приложения (см. .github/workflows).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYER="$ROOT/apps/web_player"
TARGET_DIR="$ROOT/apps/main_app/assets/web_player"
TARGET="$TARGET_DIR/quest_web_template.zip"

echo "==> сборка оболочки: flutter build web"
# MSYS/Git Bash на Windows иначе превращает «/» в «C:/Program Files/Git/»:
# аргумент --base-href приходит во Flutter уже путём и сборка падает.
(cd "$PLAYER" && flutter pub get >/dev/null && \
  MSYS_NO_PATHCONV=1 flutter build web --release --base-href / --no-web-resources-cdn)

BUILD="$PLAYER/build/web"
if [[ ! -f "$BUILD/index.html" ]]; then
  echo "нет $BUILD/index.html" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -a "$BUILD/." "$TMP/"

# Балласт: символы отладочных сборок и варианты CanvasKit для wasm-рендерера.
# Оболочка собрана dart2js и грузит canvaskit/chromium (или canvaskit.wasm),
# остальное в архив не кладём — это половина размера.
rm -f "$TMP"/canvaskit/*.symbols
rm -f "$TMP"/canvaskit/skwasm*
rm -f "$TMP"/canvaskit/wimp*
rm -rf "$TMP"/canvaskit/webparagraph
rm -f "$TMP"/.last_build_id "$TMP"/quest.mnd "$TMP"/quest_web_template.zip

# Экспорт кладут в подпапку (http://host/quest/), абсолютный / увёл бы
# запросы к wasm и assets мимо неё.
python3 - "$TMP/index.html" <<'PY'
import re, sys
path = sys.argv[1]
html = open(path, encoding='utf-8').read()
html = re.sub(r'(<base\s+href=")[^"]*(")', r'\1./\2', html, flags=re.I)
open(path, 'w', encoding='utf-8').write(html)
PY

mkdir -p "$TARGET_DIR"
rm -f "$TARGET"
# python-архиватор вместо zip: в Git Bash на Windows команды zip нет,
# а Python 3 есть и на раннерах, и на машинах разработчиков.
python3 - "$TMP" "$TARGET" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src).replace(os.sep, "/")
            archive.write(full, rel)
PY

echo "==> готово: $TARGET ($(du -h "$TARGET" | cut -f1))"