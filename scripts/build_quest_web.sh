#!/usr/bin/env bash
# Сборка standalone веб-плеера квеста: оболочка apps/web_player + quest.mnd.
#
#   ./scripts/build_quest_web.sh путь/к/квесту.mnd \
#       [--name папка] [--out dist/web] [--rebuild]
#
# Результат — папка с index.html, wasm-ядром и quest.mnd. Страницу нужно
# отдавать по HTTP (wasm не грузится с file://): любой статический сервер,
# COOP/COEP не обязательны. Каталог можно положить в любой подпуть — <base>
# переписывается на ./, а не на /play/.
#
# Оболочка собирается локально (`flutter build web --release
# --no-web-resources-cdn`): внешних запросов у страницы нет — canvaskit и
# Roboto лежат в самой папке. Без --rebuild используется уже собранный
# apps/web_player/build/web.
set -euo pipefail

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="$ROOT/apps/web_player"
QUEST=""
NAME=""
OUT_DIR="$ROOT/dist/web"
REBUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "Неизвестный флаг: $1" >&2; usage ;;
    *) QUEST="$1"; shift ;;
  esac
done

[[ -n "$QUEST" ]] || { echo "Не указан файл квеста .mnd" >&2; usage; }
[[ -f "$QUEST" ]] || { echo "Файл не найден: $QUEST" >&2; exit 1; }
QUEST="$(cd "$(dirname "$QUEST")" && pwd)/$(basename "$QUEST")"

# Папка по имени квеста: убираем только символы, недопустимые в путях и URL.
# Кириллицу не транслитерируем — в URL она кодируется, зато имя узнаваемое.
if [[ -z "$NAME" ]]; then
  NAME="$(basename "$QUEST" .mnd)"
fi
SLUG="$(printf '%s' "$NAME" \
  | sed -E 's#[/\\:*?"<>|]+#-#g; s/[[:space:]]+/-/g; s/^-+//; s/-+$//')"
[[ -n "$SLUG" ]] || SLUG="quest"

DEST="$OUT_DIR/$SLUG"

if [[ "$REBUILD" == 1 || ! -f "$SHELL_DIR/build/web/index.html" ]]; then
  echo "==> сборка оболочки (flutter build web)"
  ( cd "$SHELL_DIR" &&
    flutter build web --release --base-href / --no-web-resources-cdn )
fi

[[ -f "$SHELL_DIR/build/web/index.html" ]] \
  || { echo "Нет $SHELL_DIR/build/web — запусти с --rebuild" >&2; exit 1; }

echo "==> копирование оболочки в $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$SHELL_DIR/build/web/." "$DEST/"

# Остатки прошлых ручных сборок не должны попасть в экспорт.
rm -f "$DEST/quest.mnd" "$DEST/.last_build_id"

# Оболочка собрана под корень домена; для экспорта папку можно положить
# в любой подпуть, поэтому все ссылки делаем относительными страницы.
sed -i.bak -E 's|<base href="[^"]*">|<base href="./">|' "$DEST/index.html"
rm -f "$DEST/index.html.bak"

cp "$QUEST" "$DEST/quest.mnd"

echo "==> готово: $DEST"
echo "    отдать по HTTP, например:"
echo "      python3 -m http.server 8000 --directory \"$(dirname "$DEST")\""
echo "    и открыть http://127.0.0.1:8000/$SLUG/"