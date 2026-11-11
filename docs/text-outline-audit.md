# Обводка текста: что уже есть

Проверка пункта «добавить обводку тексту и настраивать её, если ещё нет».
Функция уже реализована сквозь модель, редактор, плеер и экспорт; отдельная
доработка не требуется.

## Модель

`packages/mnd_core/lib/models/content_item.dart`:

- `textOutlineColor` — ARGB-цвет контура; `null` = обводки нет.
- `textOutlineWidth` — толщина в px; по умолчанию `kTextOutlineWidthDefault`
  (2.0), допустимо `0.5..12`.
- `textOutlinePaint` — общая кисть для плеера и редактора (чтобы превью и игра
  рисовали одинаково).
- Поля сериализуются как `textOutlineColor`/`textOutlineWidth` и переживают
  round-trip; ширина без цвета не сохраняется (обводки нет).
- Rust-паритет: `crates/mnd-core/src/models/content_item.rs`,
  тест `text_outline_survives_roundtrip_and_stays_absent_by_default`.

## Редактор

- Обычный текст: редактор Markdown → «Стиль текста» → «Обводка»:
  цвет (свотч) и толщина (слайдер). Кнопка «убрать» снимает пару.
  `features/resources/screens/markdown_editor_screen.dart`.
- Текст как слой стека: тот же цвет/толщина в настройках слоя.
  `features/editor/screens/node_content/stack_canvas/stack_canvas_screen.dart`.
- Значения прокидываются через `content_editor_logic.dart` при сохранении.

## Плеер и экспорт

- Плеер: `content_display_factory.dart` строит два слоя `RichText` — контур
  под буквами, заливка сверху. Тот же `textOutlinePaint`.
- Веб-плеер: `apps/web_player/lib/item_view.dart` +
  `packages/mnd_player/test/widgets/text_outline_render_test.dart`.
- HTML-экспорт: `apps/main_app/test/core/services/quest_html_export_text_outline_test.dart`.

## Тесты

- `packages/mnd_core/test/models/content_item_text_outline_test.dart`
- `packages/mnd_player/test/widgets/text_outline_render_test.dart`
- `apps/main_app/test/features/resources/markdown_text_outline_test.dart`
- `apps/main_app/test/features/editor/stack_canvas_screen_test.dart`
- `apps/main_app/test/core/services/quest_html_export_text_outline_test.dart`

## Демо

`quests/tutorials/02_text.mnd` (ветка `feat/tutorial-quests`) показывает три
обводки: белую 3 px, красную 6 px и синюю 1.5 px, плюс Markdown и перенос.

## Если нужна обводка именно у подписи кнопки

Сейчас `textOutlineColor/Width` относятся к текстовым айтемам и слоям стека.
Кнопка (`ButtonItemWidget`/`GlassButton`) рисует текст через
`ButtonStyleConfig` и эти поля не читает. Это отдельная доработка: добавить
пару в `ButtonStyleConfig`, поля в редактор кнопки и два слоя `RichText` в
`GlassButton`. На текущем экране «Мои квесты» и в обычном тексте обводка уже
доступна.
