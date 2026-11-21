#!/usr/bin/env bash
# Сборка нативной библиотеки mnd-ffi (framework) для macOS и iOS
# на Apple Silicon (arm64).
#
# Для работы нужна macOS (Apple Silicon) с установленными:
#   - Rust (rustup)          — https://rustup.rs
#   - target`ы: aarch64-apple-darwin, aarch64-apple-ios,
#     aarch64-apple-ios-sim
#   - Xcode / Command Line Tools
#
# Использование:
#   ./scripts/build_ffi_apple.sh [--macos|--ios|--ios-sim|--all]
#
# По умолчанию (без аргументов) собирает всё: macOS (arm64),
# iOS (arm64 device) и iOS Simulator (arm64).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFI_DIR="$REPO_ROOT/crates/mnd-ffi"
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"

# Куда кладём готовые фреймворки
MACOS_FRAMEWORKS_DIR="$REPO_ROOT/apps/main_app/macos/Runner/Frameworks"
IOS_FRAMEWORKS_DIR="$REPO_ROOT/apps/main_app/ios/Runner/Frameworks"
PODFILE="$REPO_ROOT/apps/main_app/ios/Podfile"
IOS_MIN_DEPLOYMENT_TARGET="15.0"

# Регенерация Dart-биндингов (по умолчанию выключена)
RUN_CODEGEN="${RUN_CODEGEN:-0}"

# C-зависимости (libwebp-sys, ring, dart-sys) собираются с тем же
# IPHONEOS_DEPLOYMENT_TARGET, что и Rust. Без него cargo берёт дефолт
# таргета (iOS 10.0), а SDK-заголовки/compiler-rt уже новее — на линковке
# вылезает undefined ___chkstk_darwin. Берём версию из Podfile, но не ниже 15.
configure_ios_deployment_target() {
    local target="${IPHONEOS_DEPLOYMENT_TARGET:-}"

    if [[ -z "$target" && -f "$PODFILE" ]]; then
        target="$(sed -nE "s/^[[:space:]]*platform[[:space:]]+:ios[[:space:]]*,[[:space:]]*['\"]([0-9.]+)['\"].*/\1/p" "$PODFILE" | head -n 1)"
    fi
    target="${target:-$IOS_MIN_DEPLOYMENT_TARGET}"

    # target < IOS_MIN_DEPLOYMENT_TARGET → поднимаем до минимума.
    if awk -v target="$target" -v minimum="$IOS_MIN_DEPLOYMENT_TARGET" 'BEGIN {
        split(target, t, ".");
        split(minimum, m, ".");
        for (i = 1; i <= 3; i++) {
            if ((t[i] + 0) < (m[i] + 0)) exit 0;
            if ((t[i] + 0) > (m[i] + 0)) exit 1;
        }
        exit 1;
    }'; then
        target="$IOS_MIN_DEPLOYMENT_TARGET"
    fi

    export IPHONEOS_DEPLOYMENT_TARGET="$target"
    echo "==> IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET"
}

ensure_rust_target() {
    local target="$1"
    if ! rustup target list --installed 2>/dev/null | grep -q "^${target}$"; then
        echo "==> Устанавливаю Rust-target: $target"
        rustup target add "$target"
    fi
}

ensure_rust_targets() {
    local targets=("$@")
    for t in "${targets[@]}"; do
        ensure_rust_target "$t"
    done
}

# Кладёт готовый фреймворк в dst_dir.
# $1 = источник бинарника (dylib для macos, статический .a для ios)
# $2 = директория фреймворков
# $3 = тип (macos|ios)
install_framework() {
    local src="$1"
    local dst_dir="$2"
    local platform="$3"

    local framework_dir="$dst_dir/libmnd_ffi.framework"
    local framework_bin="$framework_dir/libmnd_ffi"

    rm -rf "$framework_dir"
    mkdir -p "$framework_dir"

    if [[ "$platform" == "macos" ]]; then
        # Динамический фреймворк для macOS. macOS не принимает «плоский»
        # framework: при валидации embedded-библиотеки Xcode требует
        # каноническую версию структуры и падает с
        # «contains Info.plist, expected Versions/Current/Resources/Info.plist
        # since the platform does not use shallow bundles». iOS-статик
        # не embed-ится, поэтому ему плоская форма не мешает.
        local versions="$framework_dir/Versions/A"
        mkdir -p "$versions/Resources"

        cp "$src" "$versions/libmnd_ffi"
        # Путь внутри бандла канонический: линкуемся «-framework libmnd_ffi»,
        # поэтому в LC_LOAD_DYLIB уходит именно эта строка, а верхние симлинки
        # остаются для инструментов, которые привыкли к плоскому
        # libmnd_ffi.framework/libmnd_ffi.
        install_name_tool -id "@rpath/libmnd_ffi.framework/Versions/A/libmnd_ffi" \
            "$versions/libmnd_ffi" 2>/dev/null || true

        cat > "$versions/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>mnd_ffi</string>
	<key>CFBundleIdentifier</key>
	<string>io.mnd.mnd-ffi</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleExecutable</key>
	<string>libmnd_ffi</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
</dict>
</plist>
PLIST

        ln -sfn A "$framework_dir/Versions/Current"
        ln -sfn Versions/Current/libmnd_ffi "$framework_dir/libmnd_ffi"
        ln -sfn Versions/Current/Resources "$framework_dir/Resources"
        ln -sfn Versions/Current/Resources/Info.plist "$framework_dir/Info.plist"
        framework_bin="$versions/libmnd_ffi"
    else
        # Статический фреймворк для iOS (линкуется, embed не нужен)
        cp "$src" "$framework_bin"
        cat > "$framework_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>mnd_ffi</string>
	<key>CFBundleIdentifier</key>
	<string>local.mnd.mnd-ffi</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleExecutable</key>
	<string>libmnd_ffi</string>
</dict>
</plist>
PLIST
    fi

    chmod +x "$framework_bin" 2>/dev/null || true
    echo "==> Готово: $framework_dir"
}

# Мёржит vendored-Lua в iOS-статик. lua-src помечает Lua флагом `-bundle`,
# поэтому объекты Lua не попадают в staticlib (`libmnd_ffi.a`) и остаются
# отдельным архивом `liblua5.4.a`. Для iOS объединяем их в один архив,
# который Xcode линкует через -force_load (иначе финальная линковка падает
# с `Undefined symbol: _lua_*`).
merge_lua_into_staticlib() {
    local target="$1"
    local lib="$2"

    local lua_lib
    lua_lib="$(find "$TARGET_DIR/$target/release/build" \
        -path '*/mlua-sys-*/out/lib/liblua5.4.a' -print -quit 2>/dev/null || true)"
    if [[ -z "$lua_lib" ]]; then
        echo "Ошибка: не найден liblua5.4.a (vendored Lua) под $TARGET_DIR/$target/release/build" >&2
        exit 1
    fi

    local merged="${lib%.a}.lua_merged.a"
    xcrun libtool -static -o "$merged" "$lib" "$lua_lib"

    # Защита от регресса: в итоговом архиве не должно остаться неопределённых
    # символов Lua (ищем подстроку, т.к. на Apple символы с префиксом `_`).
    if nm -u "$merged" 2>/dev/null | grep -q 'luaL_newstate'; then
        echo "Ошибка: Lua не вшит в $merged" >&2
        exit 1
    fi

    echo "$merged"
}

build_macos() {
    echo "==> Собираю mnd-ffi для macOS (arm64)"
    ensure_rust_targets aarch64-apple-darwin

    cargo build --release -p mnd-ffi --target aarch64-apple-darwin

    local dylib="$TARGET_DIR/aarch64-apple-darwin/release/libmnd_ffi.dylib"
    if [[ ! -f "$dylib" ]]; then
        echo "Ошибка: не найден $dylib после сборки macOS" >&2
        exit 1
    fi

    # Дефолтный dev-путь FRB для «flutter run» из репозитория: crates/mnd-ffi/target/release/
    mkdir -p "$FFI_DIR/target/release"
    rm -f "$FFI_DIR/target/release/libmnd_ffi.dylib"
    cp "$dylib" "$FFI_DIR/target/release/libmnd_ffi.dylib"

    install_framework "$dylib" "$MACOS_FRAMEWORKS_DIR" macos
}

build_ios() {
    echo "==> Собираю mnd-ffi для iOS (arm64 device)"
    configure_ios_deployment_target
    ensure_rust_targets aarch64-apple-ios

    cargo build --release -p mnd-ffi --target aarch64-apple-ios

    local lib="$TARGET_DIR/aarch64-apple-ios/release/libmnd_ffi.a"
    if [[ ! -f "$lib" ]]; then
        echo "Ошибка: не найден $lib после сборки iOS" >&2
        exit 1
    fi

    lib="$(merge_lua_into_staticlib aarch64-apple-ios "$lib")"

    install_framework "$lib" "$IOS_FRAMEWORKS_DIR" ios
}

build_ios_sim() {
    echo "==> Собираю mnd-ffi для iOS Simulator (arm64)"
    configure_ios_deployment_target
    ensure_rust_targets aarch64-apple-ios-sim

    cargo build --release -p mnd-ffi --target aarch64-apple-ios-sim

    local lib="$TARGET_DIR/aarch64-apple-ios-sim/release/libmnd_ffi.a"
    if [[ ! -f "$lib" ]]; then
        echo "Ошибка: не найден $lib после сборки iOS Simulator" >&2
        exit 1
    fi

    lib="$(merge_lua_into_staticlib aarch64-apple-ios-sim "$lib")"

    install_framework "$lib" "$IOS_FRAMEWORKS_DIR" ios
}

run_codegen_if_needed() {
    if [[ "$RUN_CODEGEN" == "1" && "$(command -v flutter_rust_bridge_codegen)" != "" ]]; then
        echo "==> flutter_rust_bridge_codegen generate"
        (cd "$REPO_ROOT" && flutter_rust_bridge_codegen generate)
    fi
}

# Make sure these dirs exist
mkdir -p "$MACOS_FRAMEWORKS_DIR" "$IOS_FRAMEWORKS_DIR"

case "${1:---all}" in
    --macos)
        build_macos
        ;;
    --ios)
        build_ios
        ;;
    --ios-sim)
        build_ios_sim
        ;;
    --all|"")
        build_macos
        build_ios
        build_ios_sim
        ;;
    *)
        echo "Неизвестный аргумент: $1"
        echo "Использование: $0 [--macos|--ios|--ios-sim|--all]"
        exit 1
        ;;
esac

run_codegen_if_needed

echo "==> Готово. Фреймворки:"
echo "    $MACOS_FRAMEWORKS_DIR/libmnd_ffi.framework"
echo "    $IOS_FRAMEWORKS_DIR/libmnd_ffi.framework"