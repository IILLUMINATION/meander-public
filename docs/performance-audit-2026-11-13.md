# Производительность: аудит (2026-11-13)

Аудит приложения `apps/main_app` (+ `packages/mnd_player`, `packages/mnd_core`,
`crates/`, `backend/`, `android/`) под две цели:

1. **работать на самом слабом Android 10**: ~2 ГБ RAM, 4×Cortex-A53, Mali-G52/G31,
   медленный eMMC;
2. **не лагать на мощных телефонах** — там причина другая, и она в документе
   выделена отдельно.

База: ветка `main` @ `534b299` (2.8.17). Код в рамках аудита не менялся; правки —
в отдельном документе (`performance-fixes-2026-11-13.md`).

Обозначения: **P0** — гарантированные фризы/OOM/невозможно пользоваться,
**P1** — заметные лаги, **P2** — накопительные микрооптимизации.
«измерено» — реальный замер, «оценка» — расчёт по объёму данных.

---

## 1. Почему лагает на мощных телефонах

Флагман не ускоряет: бюджет кадра (а на 120 Гц он вдвое меньше), однопоточный
UI-изолят Dart, загрузку текстуры в кадре, перерисовку слоя, синхронный I/O.
Именно эти четыре вещи и дают «тормозит даже на мощном».

### 1.1. Максимальная частота экрана включалась по умолчанию

- `android/app/src/main/kotlin/com/IILLUMINAT/meadner/DisplayRefreshRate.kt:84` —
  `getBoolean(PREF_KEY, true)`: на 90/120/144-Гц панели приложение просило
  максимальный режим, не спрашивая пользователя.
- На 120 Гц бюджет кадра 8,3 мс вместо 16,6: всё, что при 60 Гц укладывалось,
  начинает пропускать кадры.
- `MainActivity.kt:47-49,62` — режим применяется на `onResume` и при создании
  движка.

### 1.2. Самые дорогие эффекты включались ровно на мощных устройствах

- `packages/mnd_player/lib/utils/platform_performance.dart:88-92`:
  `backgroundBlurDisabledForMemory` режет размытие фона только при памяти
  < 4 ГБ. На 4-8 ГБ оно **включено** — то есть на флагмане хуже, чем на дешёвом
  телефоне.
- Размытие там не опциональное: `defaultBackgroundBlur = 10.0`
  (`utils/background_blur.dart:2`), и `game_screen.dart:1846-1849` применяет его
  к каждому узлу с фоновым изображением, даже если автор размытие не задавал.
- Реализация — `ImageFiltered(ImageFilter.blur)` на весь экран
  (`game_screen.dart:1858-1900`), для видео — `BackdropFilter` поверх внешней
  текстуры (`:2442-2461`). Оба пересчитываются каждый кадр.

### 1.3. Один RepaintBoundary на всё приложение и анимации без остановки

- `apps/main_app/lib/app/app.dart:79-92` — единственная корневая
  `RepaintBoundary` вокруг всего UI (для скриншотов). На 208k строк кода других
  всего 22: анимация в шапке профиля перерисовывает весь экран.
- Профиль: 18-64 частицы на кадр с `Paint()` внутри цикла
  (`features/profile/cosmetics/cosmetic_painters.dart:500-560`), `ShaderMask` на
  имени (`cosmetic_widgets.dart:568-580`), анимированный WebP 832 КБ,
  `AnimationController.repeat()` на 600 с (`cosmetic_widgets.dart:32-92`).
- Скрытые вкладки не гасятся: `TickerMode` в проекте есть только в редакторе
  (`features/editor/workspace/quest_editor_shell.dart:897,972`), а
  `VisibilityDetector` смену вкладки в `IndexedStack` не видит —
  `RenderIndexedStack` не переопределяет `paintsChild`
  (`flutter/lib/src/rendering/stack.dart:765-885`,
  `visibility_detector-0.4.0+2/lib/src/render_visibility_detector.dart:189`).

### 1.4. Глобальные socket-события перестраивали ленту и парсили markdown

- Сервер: `getIO().emit('post_stats_updated', …)` без комнат —
  `backend/src/routes/author-wall.ts:417,439,676,758`. Каждый лайк платформы
  уходит всем клиентам.
- Клиент: копия всего списка постов и `state = …` на каждое событие
  (`features/community/providers/community_feed_provider.dart:66-84`,
  `features/wall/providers/wall_paginated_provider.dart:71-90`).
- Каждый ребилд `PostCard` → `ExpandablePostText.build`: `TextPainter.layout`
  всего текста (`features/wall/widgets/expandable_post_text.dart:29-43`),
  `AppMarkdown.getConfig` (новый `MarkdownConfig` с ~10 конфигами,
  `shared/widgets/app_markdown_config.dart:22-60`), и `MarkdownBlock` из пакета —
  `StatelessWidget`, вызывающий `MarkdownGenerator.buildWidgets` в `build`
  (`markdown_widget-2.3.2+8/lib/widget/markdown_block.dart:30-32`), плюс
  `SelectionArea` на каждый пост.

### 1.5. Полноразмерные картинки → загрузка текстуры в кадре скролла

Декод 12 Мп ≈ 48 МБ ARGB; текстура грузится в GPU в том кадре, где картинка
появляется. Зависание не зависит от мощности чипа.
`CachedNetworkImage` — 19 вхождений, `memCacheWidth` — 2.

### 1.6. Блокирующая работа на UI-изоляте

- Синхронный FFI + `item.toJson()` на каждый элемент игры:
  `packages/mnd_player/lib/widgets/content_display_factory.dart:592-596` →
  `crates/mnd-ffi/src/api/game_engine.rs:609` (`#[frb(sync)]`).
- `Expression.parse` без кэша + `RegExp(...)` + два спреда карт на каждый текст
  на каждый ребилд: `packages/mnd_player/lib/services/expression_evaluator.dart:82-92`.
- `jsonDecode` всего каталога на UI-изоляте: `core/services/api_service.dart:205`;
  сервер без `limit` отдаёт весь каталог (`backend/src/routes/quests.ts:737-741`).
- Запись файла с перечитыванием и парсом:
  `packages/mnd_player/lib/utils/file_storage.dart:214-260`,
  `crates/mnd-core/src/quest_store.rs:295-325`.
- `jsonEncode(block.toJson()).hashCode` по всем блокам раз в секунду:
  `features/editor/screens/visual_script_editor/script_signature.dart:20-35`.

### 1.7. Каждое входящее сообщение перестраивало все шесть вкладок

`features/shell/screens/menu_screen.dart:197` — `ref.watch(dmUnreadCountProvider)`
в том же `build`, который возвращает `IndexedStack` с шестью экранами (`:298`).

### 1.8. `FutureBuilder` с новым Future в `build`

`packages/mnd_player/lib/widgets/glass.dart:29-62` (с `initialData: false` —
первый кадр **с** блюром), `features/resources/widgets/resource_cards.dart:322-331,512,1049`,
`features/library/screens/my_library_screen.dart:560-600`: каждый ребилд даёт
лишний кадр в промежуточном состоянии и мигание.

---

## 2. Почему не работает на слабом Android 10

### P0

| Что | Доказательство |
|---|---|
| Первый кадр ждал Firebase до 10 с | `apps/main_app/lib/app/bootstrap.dart:177-186` — `await FirebaseMessagingService().initialize().timeout(10s)` до `runApp()` (`:245`) |
| До `runApp` ещё 5 последовательных await (`.so` 6,0 МБ, языки, PackageInfo) | `bootstrap.dart:167-243`; размер `libmnd_ffi.so` — измерено 6,0 МБ (`target/release/libmnd_ffi.so`) |
| Первый кадр shell строил все 6 вкладок + их запросы | `features/shell/screens/menu_screen.dart:198-211,298` |
| Картинки ленты/постов в полном разрешении | `shared/widgets/app_markdown_config.dart:106-115`, `features/wall/widgets/post_card.dart:487,508,523,557` |
| Картинки в игре — тоже полный размер | `packages/mnd_player/lib/widgets/content_display_factory.dart:2490-2491`, тап → `PhotoView(FileImage)` `:2461` |
| Сетки ресурсов/библиотеки: полный декод + `FutureBuilder` в build | `features/resources/widgets/resource_cards.dart:322-331`, `features/library/screens/my_library_screen.dart:560-600` |
| Автосейв канваса читал весь квест каждые 1,5 с | `features/editor/providers/canvas_provider.dart:1095-1143` → `node_provider.dart:73-97` → `quest_nodes_store.dart:223-280` |
| Запись файла = 3-4× I/O (write → read → read → rename) | `file_storage.dart:214-260`, `crates/mnd-core/src/quest_store.rs:295-325` |
| JSON-кэш без границы + глубокая копия на чтение | `file_storage.dart:72,117-121,46-49,244` |
| Каталог маркета целиком, без `limit`, дважды параллельно | `features/market/providers/market_provider.dart:93,112`; `backend/src/routes/quests.ts:737-741` |

### P1

- Размытие заголовка карточки квеста на каждом кадре скролла:
  `features/market/screens/quest_market_details_screen.dart:2506-2530`.
- `setState` на 6497-строчный канвас на каждый pointer-move:
  `features/editor/screens/node_content/stack_canvas/stack_canvas_screen.dart:2523-2552`.
- PDF/импорт/бэкап/снимки квеста целиком на UI-изоляте:
  `core/services/import_service.dart:82-83,121-176`,
  `packages/mnd_player/lib/utils/key_derivation_service.dart:22-40` (PBKDF2 15000),
  `packages/mnd_player/lib/utils/quest_shot.dart:545-620`.
- До 3 живых libmpv-плееров в кэше: `packages/mnd_player/lib/services/video_cache_service.dart:12-19`.
- `imageCache.clear()` глобально при открытии ресурсов:
  `features/resources/screens/resources_screen.dart:83-84,909-910`.
- «Плавность» по умолчанию: `DisplayRefreshRate.kt:57-78,96`.
- Rust-ядро собиралось под 4 ABI, `abiFilters`/splits нет:
  `android/app/build.gradle.kts:118-121`; `useLegacyPackaging=true` + `extractNativeLibs="true"`:
  `:148-152`, `AndroidManifest.xml:12`.
- Google Fonts качались из сети в рантайме (в `pubspec` нет секции `fonts:`,
  нет бандла `assets/google_fonts/`): `core/theme/app_theme.dart:53`, 54 вызова,
  5 семейств.
- 4 записи в `SharedPreferences` каждые 10 с: `core/services/playtime_service.dart:90-121`.

### P2

- Тема собиралась дважды на каждый `build` корневого `App`:
  `app/app.dart:54-55` → `ColorScheme.fromSeed` + `ThemeData` без кэша.
- Словари локализации: 12 карт, 26 720 записей, английский из 76 спредов.
  **Измерено** (AOT-сборка, x64): 10 мс и +4,33 МБ RSS → на A53 ≈ 50-80 мс и
  те же ~4,4 МБ. Это не «сотни мс», как ожидалось.
- `assets/fonts/NotoSans-*.ttf` (1,7 МБ) не зарегистрированы как шрифты, но
  пакуются и перечитываются в PDF-сборщике.
- 88 «голых» `print(` + 129 `debugPrint(` — в release идут в logcat.
- `shared/widgets/fps_overlay.dart` — готовый FPS-оверлей, нигде не подключён.

---

## 3. Что в итоге осталось неисправленным

1. Импорт `.mnd` (PBKDF2 + AES + zip) и бэкапы — всё ещё на UI-изоляте.
2. `questsProvider` читает `config.json` всех квестов последовательно.
3. Каталог маркета: нет `limit`/пагинации (сортировка полок клиентская).
4. `SelectionArea` на каждый пост ленты.
5. media_kit/libmpv (~5,7 МБ на ABI) и `quest_player_template.apk` в assets.
6. Read-back верификация записи (осознанная защита, не трогали).
7. 4-й ABI и 32-битный x86 — выкинуты из дефолта, но сборка их поддерживает.

---

## 4. Измерения, на которые можно ссылаться

| Факт | Значение | Как получено |
|---|---|---|
| Размер Rust-ядра | 6,0 МБ | `du target/release/libmnd_ffi.so` |
| Словари локализации | 26 720 записей; 10 мс, +4,33 МБ | AOT-сборка `dart compile exe`, замер RSS |
| libmpv (media_kit 1.3.8) | 5,73 МБ (arm64) сжатых | jar из gradle-кэша |
| Декод фото 12 Мп | ~48 МБ ARGB | W×H×4 |
| Снимок квеста (402×874 @3x) | 1206×2622 → 12,6 МБ raw RGBA | `quest_shot.dart:545-620` |
| Кэш картинок Flutter по умолчанию | 100 МиБ / 1000 картинок | `PaintingBinding.imageCache` |