#!/usr/bin/env bash
# Пересобрать значки файла .mnd из assets/icon/mnd_file.svg.
#
# Нужно после правки SVG: Linux получает PNG по размерам, Windows — один .ico,
# macOS — .icns. Требуются rsvg-convert и python3 с Pillow.
set -euo pipefail

cd "$(dirname "$0")/../.."
SVG=assets/icon/mnd_file.svg
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for s in 16 24 32 48 64 128 256 512; do
  rsvg-convert -w "$s" -h "$s" "$SVG" -o "$TMP/$s.png"
  install -Dm644 "$TMP/$s.png" "linux/runner/icons/hicolor/${s}x${s}/apps/x-meander.png"
done
install -Dm644 "$SVG" linux/runner/icons/hicolor/scalable/apps/x-meander.svg

python3 - "$TMP" <<'PY'
import sys, pathlib
from PIL import Image

tmp = pathlib.Path(sys.argv[1])
sizes = [16, 24, 32, 48, 64, 128, 256]
imgs = [Image.open(tmp / f"{s}.png").convert("RGBA") for s in sizes]
imgs[-1].save(
    "windows/runner/resources/mnd_file.ico",
    format="ICO",
    sizes=[(s, s) for s in sizes],
    append_images=imgs[:-1],
)
Image.open(tmp / "512.png").convert("RGBA").save(
    "macos/Runner/MndDocument.icns", format="ICNS"
)
print("icons rebuilt")
PY
