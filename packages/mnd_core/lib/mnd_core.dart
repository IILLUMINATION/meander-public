/// Barrel file for `mnd_core`.
///
/// Используйте `import 'package:mnd_core/mnd_core.dart';` чтобы получить
/// доступ ко всем публичным API ядра.
library;

// Contracts (ports)
export 'contracts/audio_port.dart';
export 'contracts/core_logger.dart';
export 'contracts/quest_storage.dart';
export 'contracts/save_store.dart';
export 'contracts/script_asset_store.dart';
export 'contracts/script_engine_dependencies.dart';
export 'contracts/script_expression_engine.dart';
export 'contracts/script_runtime.dart';

// Engine — Rust FFI
export 'engine/script_executor.dart' show ScriptExecutor, ExecutionController;
export 'engine/game_engine.dart';
export 'engine/item_image_source.dart';
export 'engine/item_visibility.dart';
export 'engine/quest_resource_index.dart';
export 'engine/quest_validator.dart';
export 'engine/plugin_host.dart';
export 'engine/script_format.dart';

// Models
export 'models/content_item.dart';
export 'models/text_outline.dart';
export 'models/literary_work.dart';
export 'models/quest_descriptor.dart';
export 'models/music_track.dart';
export 'models/market_asset.dart';
export 'models/quest_project.dart';
export 'models/quest_table.dart';
export 'models/save_slot.dart';
export 'models/saved_node.dart';
export 'models/template_model.dart';
export 'models/value_format.dart';

// Runtime
export 'runtime/in_memory_script_runtime_state.dart';

// Services
export 'services/save_game_service.dart';

// Bootstrap
export 'mnd_core_bootstrap.dart';
export 'rust_bootstrap.dart';

// Utils
export 'lua_completion.dart';
