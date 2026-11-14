# Сборка релиза для iOS

iOS нельзя собрать ни на Linux, ни на Windows: нужны macOS, Xcode и подпись
Apple. Здесь — весь путь от чистого клона до загруженного в App Store Connect
архива. Для Android — `.github/workflows/build_android.yml`, для macOS —
`build_macos.yml`; iOS-сборка в CI (`ci-ios.yml`) проверяет только то, что
проект компилируется (`--no-codesign`), а подпись и загрузка остаются
ручными.

Что уже лежит в репозитории и не требует секретов: Firebase
`ios/Runner/GoogleService-Info.plist`, `PrivacyInfo.xcprivacy`, Xcode-фаза
«Build Rust core (mnd-ffi)» (`scripts/ios_ffi_phase.sh`) и guard-тесты
конфига (`apps/main_app/test/ios`). Сертификаты и provisioning profiles — нет.

## 0. Что нужно на маке

- macOS (лучше Apple Silicon) и свежий Xcode из App Store. Один раз:
  `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`
- [Homebrew](https://brew.sh), Rust (rustup), CocoaPods
- Flutter **3.47.9** — ровно эта версия (та же, что в CI:
  `FLUTTER_VERSION` в `.github/workflows/build_android.yml`). Более новый Flutter
  может разойтись с `Podfile` и плагинами.
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
```

## 4. Нативное ядро (Rust)

```bash
cd ~/meander
./scripts/build_ffi_apple.sh --ios
```

Проверка, что архив живой: пустой или без символов FRB архив линкуется
молча, а приложение падает уже на старте.

```bash
bin=apps/main_app/ios/Runner/Frameworks/libmnd_ffi.framework/libmnd_ffi
test -s "$bin" && nm -g "$bin" | grep -q frb_ && \
  nm -g "$bin" | grep -q luaL_newstate && echo "FFI OK"
```

Xcode-фаза (`scripts/ios_ffi_phase.sh`) умеет собрать ядро и сама, но внутри
лога `xcodebuild` это выглядит как зависание — лучше собрать один раз явно.

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

## 9. Если что-то упало

| Симптом | Что делать |
|---|---|
| `Undefined symbol: frb_*` | ядро не собралось или архив пустой → шаг 4 и проверка `nm` |
| «range of supported deployment target versions is 15.0…» | `rm -rf ios/Pods ios/Podfile.lock && cd ios && pod install --repo-update` |
| «No signing certificate» / «no profiles» | не выбран Team в Xcode (шаг 5) |
| `MissingPluginException` на старте | не прогнан `pod install` → `cd ios && pod install` |
| Падение сразу после сплэша | в `Frameworks/libmnd_ffi.framework` архив от другого среза → шаг 4 |

## 10. Чего не делать

- Не собирать релиз с `main` — только с тега.
- Не менять Bundle Identifier.
- Не ставить Flutter новее 3.47.9 и melos 7/8.
- Не коммитить `ios/Pods` и `ios/Runner/Frameworks/libmnd_ffi.framework` — они
  генерируются (`pod install` и Xcode-фаза). `ios/Podfile.lock` наоборот стоит
  коммитить: он фиксирует версии подов и делает сборки воспроизводимыми.