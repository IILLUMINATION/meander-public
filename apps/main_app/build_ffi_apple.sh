#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# ИНСТРУКЦИЯ ПО ИСПОЛЬЗОВАНИЮ
#
# 1. Сборка и запуск для iOS Simulator:
#    cd apps/main_app && ./build_ffi_apple.sh --ios-sim
#    open -a Simulator && flutter run
#
# 2. Сборка для физического iOS устройства / LiveContainer (.ipa):
#    cd apps/main_app && ./build_ffi_apple.sh --ios
#    cd apps/main_app && flutter build ipa --no-codesign
#
# Что делает этот скрипт:
# - Исправляет опечатки (#include?) и добавляет FRAMEWORK_SEARCH_PATHS в .xcconfig
# - Компилирует Rust-библиотеку (mnd-ffi) и вшивает в неё vendored Lua
# - Собирает готовый libmnd_ffi.framework для iOS / Simulator
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFI_DIR="$REPO_ROOT/crates/mnd-ffi"
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"

MACOS_FRAMEWORKS_DIR="$REPO_ROOT/apps/main_app/macos/Runner/Frameworks"
IOS_FRAMEWORKS_DIR="$REPO_ROOT/apps/main_app/ios/Runner/Frameworks"
PODFILE="$REPO_ROOT/apps/main_app/ios/Podfile"
IOS_MIN_DEPLOYMENT_TARGET="15.0"

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

# Вшиваем vendored-Lua в статический архив iOS
merge_lua_into_staticlib() {
    local target="$1"; local lib="$2"
    local lua_lib
    
    lua_lib="$(find "$TARGET_DIR/$target/release/build" \
        -path '*/mlua-sys-*/out/lib/liblua5.4.a' -print -quit 2>/dev/null || true)"
        
    if [[ -z "$lua_lib" ]]; then
        echo "Ошибка: не найден liblua5.4.a (vendored Lua) под $TARGET_DIR/$target/release/build" >&2
        exit 1
    fi
    
    local merged="${lib%.a}.lua_merged.a"
    xcrun libtool -static -o "$merged" "$lib" "$lua_lib"

    if nm -u "$merged" 2>/dev/null | grep -q 'luaL_newstate'; then
        echo "Ошибка: Lua не вшит в $merged" >&2
        exit 1
    fi
    
    echo "$merged"
}

install_framework() {
    local src="$1"
    local dst_dir="$2"
    local platform="$3"

    local framework_dir="$dst_dir/libmnd_ffi.framework"

    rm -rf "$framework_dir"
    mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"

    if [[ "$platform" == "macos" ]]; then
        cp "$src" "$framework_dir/libmnd_ffi"
        install_name_tool -id "@rpath/libmnd_ffi.framework/libmnd_ffi" "$framework_dir/libmnd_ffi" 2>/dev/null || true
    else
        cp "$src" "$framework_dir/libmnd_ffi"
    fi

    cat > "$framework_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>libmnd_ffi</string>
	<key>CFBundleIdentifier</key>
	<string>io.mnd.mnd-ffi</string>
	<key>CFBundleName</key>
	<string>libmnd_ffi</string>
	<key>CFBundleFrameworkVersion</key>
	<string>A</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
PLIST

    cat > "$framework_dir/Modules/module.modulemap" <<MODULEMAP
framework module libmnd_ffi {
  umbrella header "libmnd_ffi.h"
  export *
  module * { export * }
}
MODULEMAP

    touch "$framework_dir/Headers/libmnd_ffi.h"
    chmod +x "$framework_dir/libmnd_ffi" 2>/dev/null || true
    echo "==> Готово: $framework_dir"
}

build_ios_sim() {
    echo "==> Собираю mnd-ffi для iOS Simulator (arm64)"
    configure_ios_deployment_target
    ensure_rust_target aarch64-apple-ios-sim

    cargo build --release -p mnd-ffi --target aarch64-apple-ios-sim

    local lib="$TARGET_DIR/aarch64-apple-ios-sim/release/libmnd_ffi.a"
    if [[ ! -f "$lib" ]]; then
        echo "Ошибка: не найден $lib после сборки iOS Simulator" >&2
        exit 1
    fi
    
    lib="$(merge_lua_into_staticlib aarch64-apple-ios-sim "$lib")"
    install_framework "$lib" "$IOS_FRAMEWORKS_DIR" ios
}

build_ios() {
    echo "==> Собираю mnd-ffi для iOS (arm64)"
    configure_ios_deployment_target
    ensure_rust_target aarch64-apple-ios

    cargo build --release -p mnd-ffi --target aarch64-apple-ios

    local lib="$TARGET_DIR/aarch64-apple-ios/release/libmnd_ffi.a"
    if [[ ! -f "$lib" ]]; then
        echo "Ошибка: не найден $lib после сборки iOS" >&2
        exit 1
    fi
    
    lib="$(merge_lua_into_staticlib aarch64-apple-ios "$lib")"
    install_framework "$lib" "$IOS_FRAMEWORKS_DIR" ios
}

mkdir -p "$MACOS_FRAMEWORKS_DIR" "$IOS_FRAMEWORKS_DIR"

case "${1:---ios-sim}" in
    --ios-sim)
        build_ios_sim
        ;;
    --ios)
        build_ios
        ;;
    *)
        echo "Используй: $0 --ios-sim или --ios"
        exit 1
        ;;
esac