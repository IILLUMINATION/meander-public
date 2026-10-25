<p align="center">
  <img src="docs/logo.svg" width="96" alt="Meander">
</p>

<h1 align="center">Meander</h1>

<p align="center">
  Открытый движок текстовых квестов и визуальных новелл.<br>
  Редактор, плеер и каталог сообщества — без программирования.
</p>

<p align="center">
  <strong>Русский</strong> · <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="#установка"><img alt="Платформы: Android, iOS, Linux, Windows, macOS" src="https://img.shields.io/badge/Android%20%C2%B7%20iOS%20%C2%B7%20Linux%20%C2%B7%20Windows%20%C2%B7%20macOS-2f2f2f"></a>
  <a href="https://flutter.dev"><img alt="Flutter" src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white"></a>
  <a href="https://www.rust-lang.org"><img alt="Rust" src="https://img.shields.io/badge/Rust-000000?logo=rust&logoColor=white"></a>
  <a href="LICENSE"><img alt="Лицензия: AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-blue"></a>
  <a href="https://aur.archlinux.org/packages/meander-bin"><img alt="AUR" src="https://img.shields.io/aur/version/meander-bin?label=AUR"></a>
  <a href="https://meander.sbs"><img alt="Сайт" src="https://img.shields.io/badge/meander.sbs-quest%20catalogue-informational"></a>
</p>

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/editor.webp" width="220" alt="Граф нод"><br><sub>Граф нод</sub></td>
    <td align="center"><img src="docs/screenshots/scripting.webp" width="220" alt="Визуальные скрипты"><br><sub>Скрипты</sub></td>
    <td align="center"><img src="docs/screenshots/player.webp" width="220" alt="Плеер"><br><sub>Плеер</sub></td>
    <td align="center"><img src="docs/screenshots/community.webp" width="220" alt="Каталог сообщества"><br><sub>Каталог</sub></td>
  </tr>
</table>

## Установка

| Платформа | Способ |
|---|---|
| Android | [Google Play](https://play.google.com/store/apps/details?id=com.IILLUMINAT.meadner); APK — только своя сборка (ключ подписи в репозиторий не входит) |
| Linux | AUR [`meander-bin`](https://aur.archlinux.org/packages/meander-bin) или `Meander-linux-x64.AppImage` из релиза |
| Windows | `Release.Windows.zip` из релиза |
| macOS | `Release.Macos.zip` из релиза (Apple Silicon) |
| iOS | из исходников; в App Store сборки нет |
| Браузер | [meander.sbs](https://meander.sbs), квесты открываются на `/play/` |

## Структура репозитория

```
apps/main_app/        Flutter-клиент: Android, iOS, Linux, Windows, macOS
apps/builder_web/     веб-интерфейс для автоматической сборки APK квестов
apps/quest_player/    отдельный Flutter-плеер для индивидуальных квестов
apps/web_player/      wasm-сборка движка для браузера
backend/              старый Node/TS API; заменяется на crates/mnd-server
crates/mnd-core/      движок: модели, исполнитель скриптов, рантайм
crates/mnd-ffi/       мост Rust ↔ Dart (flutter_rust_bridge)
crates/mnd-plugin/    хост Lua-плагинов
crates/mnd-server/    API: axum, sqlx, socketioxide
crates/mnd-cli/       консольные инструменты
crates/mnd-tui/       терминальный клиент
packages/mnd_core/    Dart-биндинги Rust-ядра (flutter_rust_bridge)
packages/mnd_player/  переиспользуемый виджет плеера
plugins/              примеры Lua-плагинов
```

## Сборка из исходников

Нужны Flutter (версия в `apps/main_app/pubspec.yaml`), Rust 1.85+, JDK 17 и melos.

```bash
git clone https://github.com/IILLUMINATION/meander-public.git
cd meander-public
dart pub global activate melos
melos bootstrap
cd apps/main_app && flutter run -d linux
```

Melos берётся из корневого `pubspec.yaml` (6.3.3): версии 7 и 8 не читают
`melos.yaml`. После пересборки Rust-ядра `flutter run` нужно перезапускать —
hot reload не подхватывает новую `.so`.

### OAuth

Вход через Google, Яндекс и Telegram требует собственных OAuth-клиентов.
Скопируйте `apps/main_app/.env.example` в `apps/main_app/.env`, заполните
нужные переменные и передайте файл при сборке:

```bash
cd apps/main_app
flutter build linux --release --dart-define-from-file=.env
```

`flutter run` принимает тот же флаг. Без `.env` приложение собирается, но
соответствующие кнопки входа отключаются.

Нативной части iOS и Android значения нужны отдельно: скопируйте
`apps/main_app/ios/Flutter/OAuth.xcconfig.example` в `OAuth.xcconfig`
(он в `.gitignore`), а для Android передайте `YANDEX_CLIENT_ID` и
`TELEGRAM_CLIENT_ID` через `-PИМЯ=...` или `gradle.properties`.

<details>
<summary>Linux</summary>

`apps/main_app/linux/CMakeLists.txt` собирает ядро при каждой сборке Flutter.
Вручную:

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

Gradle-задача `buildMndFfiAndroid` собирает ядро под четыре ABI. Подпись:
`keyAlias`, `keyPassword`, `storeFile`, `storePassword` в
`apps/main_app/android/key.properties` (файл в `.gitignore`).

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
<summary>macOS и iOS</summary>

```bash
./scripts/build_ffi_apple.sh --macos
./scripts/build_ffi_apple.sh --ios        # устройство, arm64
./scripts/build_ffi_apple.sh --ios-sim    # симулятор
```

Сборки для симулятора и устройства занимают один слот фреймворка: собирай ту,
которую запускаешь. Подпись устройства настраивается в Xcode
(`ios/Runner.xcworkspace` → Runner → Signing & Capabilities) и в репозитории
не хранится.

</details>

## Проверки

```bash
melos run analyze:flutter --no-select
melos run test:flutter --no-select
cargo test --workspace
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
```

`--no-select` обязателен: без него melos спрашивает пакет и падает без TTY.
`analyze:flutter` возвращает 1 при любом замечании; ошибок в снимке нет.

## Участие

Issues и pull requests. Коммиты — [Conventional Commits](https://www.conventionalcommits.org/).

## Безопасность

Уязвимости — приватно через
[GitHub Security Advisories](https://github.com/IILLUMINATION/meander-public/security/advisories/new),
не публичным issue.

## Лицензия

AGPL-3.0-or-later — см. [LICENSE](LICENSE). Сетевое использование считается
распространением: изменённые версии, доступные по сети, обязаны публиковать
исходники под той же лицензией. Коммерческое использование не запрещено —
лицензия ограничивает только распространение изменённых версий.

Сторонние ассеты — по своим лицензиям: Noto Sans (SIL OFL 1.1) в
`apps/main_app/assets/fonts/`, Rust- и Dart-зависимости.
