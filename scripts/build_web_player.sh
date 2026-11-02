#!/usr/bin/env bash
# Сборка веб-плеера: wasm-ядро с threads + Flutter web с base href /play/.
#
# Без shared memory WorkerPool во flutter_rust_bridge падает с DataCloneError
# (WebAssembly.Memory нельзя postMessage-нуть), а без --base-href /play/
# относительный flutter_bootstrap.js ищется в корне домена и даёт 404.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

rustup target add wasm32-unknown-unknown >/dev/null

export RUSTFLAGS="-C target-feature=+atomics,+bulk-memory,+mutable-globals \
-C link-arg=--shared-memory \
-C link-arg=--import-memory \
-C link-arg=--export=__wasm_init_tls \
-C link-arg=--export=__tls_size \
-C link-arg=--export=__tls_align \
-C link-arg=--export=__tls_base \
-C link-arg=--max-memory=2147483648"

cargo build -p mnd-ffi --target wasm32-unknown-unknown --release --no-default-features

wasm-bindgen target/wasm32-unknown-unknown/release/mnd_ffi.wasm \
  --out-dir apps/web_player/web/pkg/v2 \
  --out-name mnd_ffi \
  --target no-modules \
  --no-typescript

# Версия в пути — чтобы старый service worker/Cloudflare не подсунул
# несовместимую пару JS+wasm после обновления.
sed -i 's/maximum:32768/maximum:2048/g' apps/web_player/web/pkg/v2/mnd_ffi.js

cd apps/web_player
flutter build web --release --base-href /play/

# Важно: wasm/JS из web/pkg попадают в build/web/pkg на этапе flutter build,
# поэтому пересборка ядра должна идти строго перед flutter build.
echo "==> готово: apps/web_player/build/web"