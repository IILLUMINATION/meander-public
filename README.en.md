<p align="center">
  <img src="docs/logo.svg" width="96" alt="Meander">
</p>

<h1 align="center">Meander</h1>

<p align="center">
  An open-source engine for text quests and visual novels.<br>
  Editor, player and community catalogue — no programming required.
</p>

<p align="center">
  <a href="README.md">Русский</a> · <strong>English</strong>
</p>

<p align="center">
  <a href="#install"><img alt="Platforms: Android, iOS, Linux, Windows, macOS" src="https://img.shields.io/badge/Android%20%C2%B7%20iOS%20%C2%B7%20Linux%20%C2%B7%20Windows%20%C2%B7%20macOS-2f2f2f"></a>
  <a href="https://flutter.dev"><img alt="Flutter" src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white"></a>
  <a href="https://www.rust-lang.org"><img alt="Rust" src="https://img.shields.io/badge/Rust-000000?logo=rust&logoColor=white"></a>
  <a href="LICENSE"><img alt="License: AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-blue"></a>
  <a href="https://aur.archlinux.org/packages/meander-bin"><img alt="AUR" src="https://img.shields.io/aur/version/meander-bin?label=AUR"></a>
  <a href="https://meander.sbs"><img alt="Website" src="https://img.shields.io/badge/meander.sbs-quest%20catalogue-informational"></a>
</p>

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/editor.webp" width="220" alt="Node graph editor"><br><sub>Node graph</sub></td>
    <td align="center"><img src="docs/screenshots/scripting.webp" width="220" alt="Visual scripting"><br><sub>Scripting</sub></td>
    <td align="center"><img src="docs/screenshots/player.webp" width="220" alt="Player"><br><sub>Player</sub></td>
    <td align="center"><img src="docs/screenshots/community.webp" width="220" alt="Community catalogue"><br><sub>Catalogue</sub></td>
  </tr>
</table>

## Install

| Platform | How |
|---|---|
| Android | [Google Play](https://play.google.com/store/apps/details?id=com.IILLUMINAT.meadner); APK from source only (the signing key is not in the repository) |
| Linux | AUR [`meander-bin`](https://aur.archlinux.org/packages/meander-bin) or `Meander-linux-x64.AppImage` from a release |
| Windows | `Release.Windows.zip` from a release |
| macOS | `Release.Macos.zip` from a release (Apple Silicon) |
| iOS | build from source; no App Store build |
| Browser | [meander.sbs](https://meander.sbs), quests open at `/play/` |

## Repository layout

```
apps/main_app/        Flutter client: Android, iOS, Linux, Windows, macOS
apps/builder_web/     web interface for automated quest APK builds
apps/quest_player/    standalone Flutter player for individual quests
apps/web_player/      wasm build of the engine for the browser
backend/              legacy Node/TS API; replaced by crates/mnd-server
crates/mnd-core/      engine: models, script executor, runtime
crates/mnd-ffi/       Rust ↔ Dart bridge (flutter_rust_bridge)
crates/mnd-plugin/    Lua plugin host
crates/mnd-server/    API: axum, sqlx, socketioxide
crates/mnd-cli/       command-line tools
crates/mnd-tui/       terminal client
packages/mnd_core/    Dart bindings for the Rust core (flutter_rust_bridge)
packages/mnd_player/  reusable quest player widget
plugins/              example Lua plugins
```

## Building from source

You need Flutter (version in `apps/main_app/pubspec.yaml`), Rust 1.85+, JDK 17
and melos.

```bash
git clone https://github.com/IILLUMINATION/meander-public.git
cd meander-public
dart pub global activate melos
melos bootstrap
cd apps/main_app && flutter run -d linux
```

Melos comes from the root `pubspec.yaml` (6.3.3): versions 7 and 8 do not read
`melos.yaml`. Restart `flutter run` after rebuilding the Rust core — hot reload
does not load a new `.so`.

### OAuth

Google, Yandex and Telegram login require your own OAuth clients. Copy
`apps/main_app/.env.example` to `apps/main_app/.env`, fill in the values you
need and pass the file at build time:

```bash
cd apps/main_app
flutter build linux --release --dart-define-from-file=.env
```

`flutter run` accepts the same flag. Without `.env` the app still builds, but
the corresponding sign-in buttons are disabled.

The native iOS and Android parts need their own values: copy
`apps/main_app/ios/Flutter/OAuth.xcconfig.example` to `OAuth.xcconfig`
(it is in `.gitignore`); on Android pass `YANDEX_CLIENT_ID` and
`TELEGRAM_CLIENT_ID` via `-PNAME=...` or `gradle.properties`.

<details>
<summary>Linux</summary>

`apps/main_app/linux/CMakeLists.txt` builds the core on every Flutter build.
Manually:

```bash
./scripts/setup_ffi_link.sh
./scripts/build_ffi.sh
```

</details>

<details>
<summary>Android</summary>

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi \
    x86_64-linux-android i686-linux-android
cargo install cargo-ndk
cd apps/main_app
flutter build apk --flavor prod --release
```

The Gradle task `buildMndFfiAndroid` builds the core for four ABIs. Signing:
`keyAlias`, `keyPassword`, `storeFile`, `storePassword` in
`apps/main_app/android/key.properties` (git-ignored).

</details>

<details>
<summary>Windows</summary>

```bash
cargo build --release -p mnd-ffi
cd apps/main_app && flutter build windows --release
cp ../../target/release/mnd_ffi.dll build/windows/x64/runner/Release/
```

</details>

<details>
<summary>macOS and iOS</summary>

```bash
./scripts/build_ffi_apple.sh --macos
./scripts/build_ffi_apple.sh --ios        # device, arm64
./scripts/build_ffi_apple.sh --ios-sim    # simulator
```

The simulator and device builds share one framework slot: build the one you are
about to run. Device signing is set up in Xcode (`ios/Runner.xcworkspace` →
Runner → Signing & Capabilities) and is not stored in the repository.

</details>

## Checks

```bash
melos run analyze:flutter --no-select
melos run test:flutter --no-select
cargo test --workspace
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
```

`--no-select` is required: without it melos asks for a package and fails with
no TTY. `analyze:flutter` exits 1 on any issue; this snapshot has no errors.

## Contributing

Issues and pull requests. Commits follow
[Conventional Commits](https://www.conventionalcommits.org/).

## Security

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/IILLUMINATION/meander-public/security/advisories/new),
not in a public issue.

## License

AGPL-3.0-or-later — see [LICENSE](LICENSE). Network use counts as distribution:
modified versions served over a network must publish their source under the same
license. Commercial use is not prohibited — the license only constrains
distribution of modified versions.

Third-party assets keep their own terms: Noto Sans (SIL OFL 1.1) in
`apps/main_app/assets/fonts/`, Rust and Dart dependencies.
