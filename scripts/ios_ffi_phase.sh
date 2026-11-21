#!/usr/bin/env bash
# Xcode Run Script phase «Build Rust core (mnd-ffi)».
#
# iOS-сборка линкуется с -force_load на Runner/Frameworks/libmnd_ffi.framework,
# а этот архив в git не лежит (каталог специально пуст). Без него ссылка падает,
# а если архир был собран из старой копии — на старте отваливается FRB.
# Фейз собирает архив сам и проверяет, что он соответствует срезу (device/sim).
#
# Вызывается только из-под Xcode на macOS. На Linux/Windows это no-op:
# iOS там собрать нельзя, а gradle/cargo-пути трогать незачем.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORK_DIR="$REPO_ROOT/apps/main_app/ios/Runner/Frameworks"
FRAMEWORK_BIN="$FRAMEWORK_DIR/libmnd_ffi.framework/libmnd_ffi"
TRIPLE_STAMP="$FRAMEWORK_DIR/.built-triple"

# PLATFORM_NAME приходит из Xcode; из командной строки можно задать вручную.
platform="${PLATFORM_NAME:-${MND_IOS_PLATFORM:-iphoneos}}"

case "$platform" in
    iphonesimulator)
        # build_ffi_apple.sh собирает симулятор только под arm64 (Apple Silicon).
        triple="aarch64-apple-ios-sim"
        mode="--ios-sim"
        ;;
    *)
        triple="aarch64-apple-ios"
        mode="--ios"
        ;;
esac

need_build() {
    if [[ ! -f "$FRAMEWORK_BIN" ]]; then
        echo "==> Архив mnd-ffi отсутствует — собираю $triple"
        return 0
    fi
    if [[ "$(cat "$TRIPLE_STAMP" 2>/dev/null)" != "$triple" ]]; then
        echo "==> В Frameworks лежит срез «$(cat "$TRIPLE_STAMP" 2>/dev/null || echo '?')», нужен $triple — пересобираю"
        return 0
    fi
    # Свежесть: любой исходник ядра новее архива.
    if find "$REPO_ROOT/crates" -name '*.rs' -newer "$FRAMEWORK_BIN" 2>/dev/null | grep -q .; then
        echo "==> Rust-исходники свежее архива — пересобираю $triple"
        return 0
    fi
    echo "==> libmnd_ffi.framework актуален ($triple)"
    return 1
}

if need_build; then
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "!! iOS-сборка требует macOS с Xcode и Rust; собираю на $(uname -s) — пропускаю."
        echo "!! Этот путь не должен вести к архиву в App Store."
    elif ! command -v cargo >/dev/null 2>&1; then
        echo "!! cargo не найден. Установите Rust (https://rustup.rs), затем:"
        echo "!!   rustup target add $triple"
        exit 1
    else
        "$REPO_ROOT/scripts/build_ffi_apple.sh" "$mode" || exit 1
        mkdir -p "$FRAMEWORK_DIR"
        printf '%s' "$triple" > "$TRIPLE_STAMP"
    fi
fi

# Финальная страховка: лучше понятная ошибка здесь, чем невнятная на линковке.
if [[ ! -s "$FRAMEWORK_BIN" ]]; then
    echo "!! $FRAMEWORK_BIN отсутствует или пуст."
    echo "!! Соберите ядро вручную: ./scripts/build_ffi_apple.sh $mode"
    exit 1
fi

# Пустой или чужой архив линкуется молча: `-force_load` не жалуется, а на
# старте FRB не находит `frb_*`/Lua и приложение остаётся на launch screen.
# Проверяем символы прямо в фазе сборки, чтобы битый архив не доехал до тестера.
if [[ "$(uname -s)" == "Darwin" ]] && command -v nm >/dev/null 2>&1; then
    symbols="$(nm -g "$FRAMEWORK_BIN" 2>/dev/null || true)"
    # Проверяем именно тот символ, который FRB ищет при инициализации.
    # Общего `frb_` мало: в архиве могут остаться диспетчеры, а хеш
    # контента вырезан — приложение упадёт уже на устройстве.
    for required in frb_get_rust_content_hash frb_pde_ffi_dispatcher_primary; do
        if ! grep -q "$required" <<< "$symbols"; then
            echo "!! В $FRAMEWORK_BIN нет символа $required — это не собранное Rust-ядро."
            echo "!! Пересоберите: ./scripts/build_ffi_apple.sh $mode"
            exit 1
        fi
    done
    if ! grep -q 'luaL_newstate' <<< "$symbols"; then
        echo "!! В $FRAMEWORK_BIN нет luaL_newstate — vendored Lua не вшит."
        echo "!! Пересоберите: ./scripts/build_ffi_apple.sh $mode"
        exit 1
    fi
    arch="$(lipo -info "$FRAMEWORK_BIN" 2>/dev/null || true)"
    if ! grep -q 'arm64' <<< "$arch"; then
        echo "!! $FRAMEWORK_BIN собран не под arm64: $arch"
        echo "!! Нужен срез $triple, пересоберите: ./scripts/build_ffi_apple.sh $mode"
        exit 1
    fi
fi

exit 0
