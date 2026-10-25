#!/usr/bin/env bash
# Сборщик квестов в APK: упаковывает один .mnd в standalone-плеер
# (apps/quest_player на основе packages/mnd_player).
#
#   ./scripts/build_quest_apk.sh путь/к/квесту.mnd \
#       --name "Мой квест" --id com.example.myquest \
#       [--version 1.0.0] [--build-number 1] [--icon icon.png] \
#       [--abi all|arm64|arm|x64] [--out dist/]
#
# Нужны: Flutter, Rust + cargo-ndk, Android SDK/NDK 28.2.13676358, JDK 17.
# Подпись: apps/quest_player/android/key.properties (иначе debug-ключ).
set -euo pipefail

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/quest_player"

QUEST=""
NAME=""
APP_ID=""
VERSION="1.0.0"
BUILD_NUMBER="1"
ICON=""
ABI="all"
OUT_DIR="$ROOT/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --id) APP_ID="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --icon) ICON="$2"; shift 2 ;;
    --abi) ABI="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "Неизвестный флаг: $1" >&2; usage ;;
    *) QUEST="$1"; shift ;;
  esac
done

[[ -n "$QUEST" ]] || { echo "Не указан файл квеста .mnd" >&2; usage; }
[[ -f "$QUEST" ]] || { echo "Файл не найден: $QUEST" >&2; exit 1; }
QUEST="$(cd "$(dirname "$QUEST")" && pwd)/$(basename "$QUEST")"
# Дальше скрипт делает cd в apps/quest_player — относительный --out
# должен считаться от каталога, откуда скрипт запустили.
[[ "$OUT_DIR" = /* ]] || OUT_DIR="$PWD/$OUT_DIR"

# Название по умолчанию — поле title из config.json внутри квеста недоступно
# без расшифровки, поэтому берём имя файла.
if [[ -z "$NAME" ]]; then
  NAME="$(basename "$QUEST")"
  NAME="${NAME%.*}"
fi

if [[ -z "$APP_ID" ]]; then
  slug="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  [[ "$slug" =~ ^[a-z] ]] || slug="q${slug}"
  APP_ID="sbs.meander.quest.${slug:-game}"
fi
if ! [[ "$APP_ID" =~ ^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$ ]]; then
  echo "Неверный --id «$APP_ID»: нужен вид com.example.quest" >&2
  exit 1
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "--build-number должен быть числом" >&2; exit 1; }

case "$ABI" in
  all) ABIS="arm64-v8a,armeabi-v7a,x86_64"; PLATFORMS="android-arm64,android-arm,android-x64" ;;
  arm64) ABIS="arm64-v8a"; PLATFORMS="android-arm64" ;;
  arm) ABIS="armeabi-v7a"; PLATFORMS="android-arm" ;;
  x64) ABIS="x86_64"; PLATFORMS="android-x64" ;;
  *) echo "--abi: all | arm64 | arm | x64" >&2; exit 1 ;;
esac

if [[ -n "$ICON" ]]; then
  [[ -f "$ICON" ]] || { echo "Иконка не найдена: $ICON" >&2; exit 1; }
  ICON="$(cd "$(dirname "$ICON")" && pwd)/$(basename "$ICON")"
fi

# android:label подставляется в XML как есть — экранируем спецсимволы.
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

for tool in flutter cargo; do
  command -v "$tool" >/dev/null || { echo "Не найден $tool в PATH" >&2; exit 1; }
done

echo "==> Квест:    $QUEST"
echo "==> Название: $NAME"
echo "==> ID:       $APP_ID"
echo "==> Версия:   $VERSION ($BUILD_NUMBER), ABI: $ABIS"

mkdir -p "$APP_DIR/assets/quest"
cp "$QUEST" "$APP_DIR/assets/quest/quest.mnd"
trap 'rm -f "$APP_DIR/assets/quest/quest.mnd"' EXIT

export ORG_GRADLE_PROJECT_questAppId="$APP_ID"
export ORG_GRADLE_PROJECT_questAppName="$(xml_escape "$NAME")"
export ORG_GRADLE_PROJECT_questAbis="$ABIS"
export ORG_GRADLE_PROJECT_questIcon="$ICON"

cd "$APP_DIR"
flutter pub get
flutter build apk --release \
  --target-platform "$PLATFORMS" \
  --build-name "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --dart-define="QUEST_APP_NAME=$NAME"

mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/${APP_ID}-${VERSION}.apk"
cp "$APP_DIR/build/app/outputs/flutter-apk/app-release.apk" "$OUT_FILE"
echo "==> Готово: $OUT_FILE"
