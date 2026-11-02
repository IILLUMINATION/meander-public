#!/usr/bin/env bash
# Сборка веб-оболочки Meander.
#
# Wasm-ядро лежит в apps/web_player/web/pkg/v2 и закреплено вместе с оболочкой:
# это единственная проверенная пара JS+wasm для текущего FRB/worker pool.
# Пересобирать ядро из текущего Rust можно, но тогда нужно согласовать
# rustContentHash в packages/mnd_core/lib/src/gen/frb_generated.dart и
# проверить worker pool в браузере.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/apps/web_player"
flutter build web --release --base-href /play/
echo "==> готово: apps/web_player/build/web (wasm: web/pkg/v2)"
