# Что осталось по перфу (аудит 2026-11-13/14)

Аудит закончен, ничего не менялось. Полный разбор с замерами — в переписке;
здесь только очередь работ, чтобы не потерять.

## P0 — ощущаемая скорость, Rust не нужен

1. **«Сценарий и главы» (TagsScreen) читает весь квест ради счётчиков.**
   - `tag_provider.dart:98-104` → `allQuestNodesProvider` → `QuestNodesStore.read` → `readAll`
     (`quest_nodes_store.dart:264-311`): последовательное чтение тела каждой ноды квеста.
   - Замер: 400 нод — 238 мс на десктопе (на телефоне ~1–2 с); плюс возможная миграция
     превью 316–358 мс (`_withCardPreviews`, `quest_nodes_store.dart:157`).
   - Фикс: считать по `readIndex` как `nodeDeletionStats` (`node_provider.dart:24-40`),
     конфиг читать один раз на экран. Ожидаемо ~30 мс.

2. **Мигание нод на канвасе.**
   - LOD решается по измеренному времени того же кадра: `canvas_painter.dart:191` + `:281` →
     `CanvasFrameCost.record` (`canvas_lod.dart:69-88`). Замер: 14 переключений за 120 кадров,
     бюджет подписей ходит 300→22→300.
   - Жёсткий порог `detailsMaxVisibleNodes = 250` (`canvas_lod.dart:16`) переключает тела у всех
     нод при пересечении границы.
   - Фикс: детализация только по зуму с гистерезисом; бюджет подписей не по EMA;
     кеш `TextPainter`/`Picture` по id ноды.

3. **Тяжёлый тик перетаскивания.**
   - Замер: 1 нода с timer/script-рёбрами — 123,6 мс/кадр; все 600 нод — 184 мс/кадр.
   - Причины: `Node.copyWith` пересоздаёт объект и сбрасывает кеши текста (`canvas_models.dart:340`);
     `_computeCanvasGeometries` пересчитывает все рёбра (`canvas_provider.dart:195`);
     кеш пунктира `_dashedPaths` ключуется идентичностью геометрии и промахивается каждый кадр
     (`canvas_painter.dart:433-452`); `SpatialHash` на строковых ключах (`canvas_models.dart:850`).
   - Фикс: кеш пунктира по `(id ребра, геометрия)`, инкрементальная геометрия, не терять кеш текста.

## P1 — в Rust

4. Индекс + превью карточек + script-рёбра строить в Rust при записи
   (сейчас `quest_nodes_store.dart:556-700` и `canvas_provider.dart:509-560` в Dart;
   в Rust уже есть `canvas_build_connections`, `canvas.rs:84-300`).
   Убирает `_withCardPreviews` и повторные чтения тел.
   `quest_build.rs:1773-1777` пишет `card_preview_version: 0` — из-за этого миграция
   запускается на первом открытии.

5. Canvas-сессия в Rust: handle + бинарный draw list (видимые ноды, геометрия рёбер,
   нарезанный пунктир, LOD). `canvas_visible_subset` (`canvas.rs:517`) уже умеет
   геометрию, но вызывается из Dart только `canvasTidyLayout` (`canvas_provider.dart:1251`).

6. Один FFI-вызов на весь текст вместо вызова на каждый `{токен}`; убрать двойной
   парсинг JSON в `quest_store_read_json` (`quest_store.rs:152` + `quest_store.dart:126-133`).

## P2 — чистка

7. Удалить `expressions` из pubspec и `ExpressionEvaluatorService` (аргумент `expressionEngine`
   в `ScriptExecutor.configure` игнорируется, `script_executor.dart:260-268`).
8. `nodeDeletionStats`/поиск по канвасу — в Rust, если понадобится.