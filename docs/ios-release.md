# Сборка релиза для iOS

iOS нельзя собрать ни на Linux, ни на Windows: нужны macOS, Xcode и подпись
Apple. Здесь — весь путь от чистого клона до загруженного в App Store Connect
архива. Для Android — `.github/workflows/build_android.yml`, для macOS —
`build_macos.yml`; iOS-сборка в CI (`ci-ios.yml`) собирает оба среза
(`--no-codesign`, симулятор и устройство) на каждом PR, который трогает
клиент, ядро или iOS-проект: несовместимость Flutter/Swift, CocoaPods и Rust
всплывает до TestFlight, а не после. Подпись и загрузка остаются ручными.

Что уже лежит в репозитории и не требует секретов: Firebase
`ios/Runner/GoogleService-Info.plist`, `PrivacyInfo.xcprivacy`, Xcode-фаза
«Build Rust core (mnd-ffi)» (`scripts/ios_ffi_phase.sh`) и guard-тесты
конфига (`apps/main_app/test/ios`). Сертификаты и provisioning profiles — нет.

## 0. Что нужно на маке

- macOS (лучше Apple Silicon) и **Xcode 26+** из App Store: `connectivity_plus`
  7.3 использует `NWPath.isUltraConstrained` из iOS 26 SDK, на Xcode 16.4
  device-сборка не компилируется. Один раз:
  `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`
- [Homebrew](https://brew.sh), Rust (rustup), CocoaPods
- Flutter **3.47.9** — ровно эта версия (та же, что в CI:
  `FLUTTER_VERSION` в `.github/workflows/build_android.yml`). Более новый Flutter
  может разойтись с `Podfile` и плагинами.
  ⚠️ Если собираете не `main`, а старый тег — берите версию из workflow **того
  среза** (`grep FLUTTER_VERSION .github/workflows/build_android.yml` после
  `git checkout`): у `v2.8.17` это была 3.47.0. Swift-код подписан на API
  движка (`FlutterSceneDelegate`), а плагин-регистранты генерируются под его
  версию: чужой движок собирается, но приложение падает сразу после запуска.
- melos **6.3.3** — 7 и 8 не читают `melos.yaml`, воркспейс на них не поднимается.
- Доступ в Apple Developer (команда с правом подписи) и в App Store Connect.
- Клон публичный, токен не нужен.

## 1. Клон на тег релиза

Собирать надо с тега, а не с `main`: после релиза в `main` уже идут следующие
коммиты. Тег — аннотированный, `git checkout` по нему даёт нужный срез.

```bash
git clone https://github.com/IILLUMINATION/meander-public.git meander
cd meander
git fetch --tags
tag=$(git tag -l 'v*' --sort=-v:refname | head -1)   # последний релиз
git checkout "$tag"
echo "$tag → $(git rev-parse HEAD)"
```

Версия и номер сборки берутся из `apps/main_app/pubspec.yaml` (`version:`),
поднимать их руками не нужно:

```bash
grep '^version:' apps/main_app/pubspec.yaml
```

## 2. Инструменты

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

brew install cocoapods

git clone -b 3.47.9 https://github.com/flutter/flutter.git "$HOME/flutter-3.47.9"
export PATH="$HOME/flutter-3.47.9/bin:$PATH"
flutter --version            # 3.47.9

dart pub global activate melos 6.3.3
export PATH="$HOME/.pub-cache/bin:$PATH"

flutter doctor -v            # Xcode и CocoaPods должны быть зелёными
```

## 3. Зависимости и проверка конфига

```bash
cd ~/meander
melos bootstrap              # воркспейс: apps/* + packages/*
cd apps/main_app
flutter pub get
flutter test test/ios        # guard-тесты Info.plist / entitlements / Rust-фазы

# Ещё раз версия движка — уже из этого среза: она обязана совпадать с §0.
flutter --version
```

`ios/Podfile.lock` в репозитории пока не лежит, поэтому первый `pod install`
на каждой машине подбирает версии подов заново. После успешной сборки
закоммитьте его — иначе два Мака соберут разные бинарники из одного коммита.

## 4. Нативное ядро (Rust)

```bash
cd ~/meander
./scripts/build_ffi_apple.sh --ios
```

Проверка, что архив живой: пустой или без символов FRB архив линкуется
молча, а приложение падает уже на старте.

```bash
bin=apps/main_app/ios/Runner/Frameworks/libmnd_ffi.framework/libmnd_ffi
test -s "$bin" && nm -g "$bin" | grep -q frb_get_rust_content_hash && \
  nm -g "$bin" | grep -q frb_pde_ffi_dispatcher_primary && \
  nm -g "$bin" | grep -q luaL_newstate && echo "FFI OK"
```

Xcode-фаза (`scripts/ios_ffi_phase.sh`) умеет собрать ядро и сама, но внутри
лога `xcodebuild` это выглядит как зависание — лучше собрать один раз явно.
Фаза теперь сама проверяет `frb_*`, `luaL_newstate` и `arm64` и роняет сборку
до подписи, если архив пустой или от другого среза.

## 5. Подпись (один раз на машину)

```bash
open apps/main_app/ios/Runner.xcworkspace
```

Xcode → таргет **Runner** → *Signing & Capabilities* → Team = своя команда,
«Automatically manage signing». Bundle Identifier уже стоит
`com.IILLUMINAT.meadner`; менять нельзя — к нему привязаны Firebase-конфиг и
запись приложения в App Store Connect.

## 6. Сборка архива и IPA

```bash
cd ~/meander/apps/main_app
flutter build ipa --release \
  --dart-define=MEANDER_API_BASE=https://meander.illuminat.dev \
  --export-method app-store
```

- `--dart-define` можно не указывать (это же значение по умолчанию), но так
  надёжнее: домен бэкенда зашивается на этапе сборки, см. `lib/core/config.dart`.
- Если `CFBundleVersion` из `pubspec.yaml` уже занят в App Store Connect
  (например, `263`), номер для загрузки задаётся флагом:
  `flutter build ipa --release --build-number 264 …`. Версию (`2.8.17`) править
  не надо — она одна на все платформы и привязана к тегу.
- Результат: `build/ios/archive/Runner.xcarchive` и `build/ios/ipa/*.ipa`.
- Время сборки ~10–15 минут, первый раз дольше (Flutter скачивает engine).

## 7. Загрузка в App Store Connect

Проще всего — **Transporter** (бесплатно в Mac App Store): перетащить `.ipa`
из `build/ios/ipa/` и нажать Upload.

Из терминала, с ключом App Store Connect API:

```bash
xcrun altool --upload-app \
  -f build/ios/ipa/*.ipa -t ios \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

Дальше App Store Connect → приложение `com.IILLUMINAT.meadner` → версия из
`pubspec.yaml` → сборка с тем же номером → TestFlight.

## 8. Проверка перед загрузкой

```bash
flutter run --release -d <udid-iphone> \
  --dart-define=MEANDER_API_BASE=https://meander.illuminat.dev
```

Минимум: старт без падений, каталог квестов грузится, редактор открывается.
Rust-ядро — первое, что отваливается при неправильном архиве.
Перед TestFlight дождитесь зелёного `CI iOS` на теге `v*` — workflow теперь
запускается и на тег, а не только на PR.

Если запуск всё же сорвался, приложение больше не остаётся на цветном
`LaunchScreen`: сразу после `runApp` показывается экран «Запуск...» с последним
шагом, а через 45 секунд или при исключении — экран ошибки с кнопкой
«Скопировать ошибку». Тестировщику достаточно прислать этот текст: в нём есть
платформа, режим сборки, шаг, время и стек. Консоль/Xcode для диагностики не
нужны.

## 9. Если что-то упало

| Симптом | Что делать |
|---|---|
| `Undefined symbol: frb_*` | ядро не собралось или архив пустой → шаг 4 и проверка `nm` |
| `Failed to lookup symbol 'frb_get_rust_content_hash'` на старте | Release/Archive вырезал глобальные символы: в таргете **Runner** должно быть `STRIP_STYLE = non-global`, `DEPLOYMENT_POSTPROCESSING = YES`, `DEAD_CODE_STRIPPING = NO`; framework линкуется через `-force_load`, но не Embed |
| «range of supported deployment target versions is 15.0…» | `rm -rf ios/Pods ios/Podfile.lock && cd ios && pod install --repo-update` |
| «No signing certificate» / «no profiles» | не выбран Team в Xcode (шаг 5) |
| `MissingPluginException` на старте | не прогнан `pod install` → `cd ios && pod install` |
| Падение сразу после сплэша | в `Frameworks/libmnd_ffi.framework` архив от другого среза → шаг 4 |
| Цветной экран без UI на старте | сначала проверьте, нет ли экрана «Не удалось запустить Meander»: он означает ошибку Dart-инициализации, текст копируется кнопкой. Если экрана нет вообще, Dart не стартовал — смотрите native-логи `[Meander] application didFinishLaunching` / `didInitializeImplicitFlutterEngine`, UIScene и версию Flutter (§0, §2) |
| Собирается, падает на телефоне, а CI зелёный | версия Flutter/регистрантов не та, что в CI (§0, §2) или архив ядра собран другой фазой (§4); реальная iOS-сборка теперь гоняется на каждом PR (`ci-ios.yml`), сверьте её лог |

## 10. Чего не делать

- Не собирать релиз с `main` — только с тега.
- Не менять Bundle Identifier.
- Не ставить Flutter новее 3.47.9 и melos 7/8.
- Не коммитить `ios/Pods` и `ios/Runner/Frameworks/libmnd_ffi.framework` — они
  генерируются (`pod install` и Xcode-фаза). `ios/Podfile.lock` наоборот стоит
  коммитить: он фиксирует версии подов и делает сборки воспроизводимыми.