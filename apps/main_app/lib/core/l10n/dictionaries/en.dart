import 'en_app.dart';
import 'en_common.dart';
import 'en_b2_analytics.dart';
import 'en_b2_app.dart';
import 'en_b2_asset_market.dart';
import 'en_b2_community.dart';
import 'en_b2_core.dart';
import 'en_b2_editor1.dart';
import 'en_b2_editor2.dart';
import 'en_b2_editor3.dart';
import 'en_b2_export.dart';
import 'en_b2_forums.dart';
import 'en_b2_game.dart';
import 'en_b2_hub.dart';
import 'en_b2_library.dart';
import 'en_b2_market.dart';
import 'en_b2_messages.dart';
import 'en_b2_music_library.dart';
import 'en_b2_plugin_host.dart';
import 'en_b2_plugins.dart';
import 'en_b2_profile.dart';
import 'en_b2_quests.dart';
import 'en_b2_resources.dart';
import 'en_b2_settings.dart';
import 'en_b2_shared.dart';
import 'en_b2_shell.dart';
import 'en_b2_undo.dart';
import 'en_b2_wall.dart';
import 'en_b3_titles.dart';
import 'en_b4_analytics.dart';
import 'en_b4_community.dart';
import 'en_b4_core.dart';
import 'en_b4_forums.dart';
import 'en_b4_hub.dart';
import 'en_b4_market.dart';
import 'en_b4_messages.dart';
import 'en_b4_plugins.dart';
import 'en_b4_profile.dart';
import 'en_b4_quests.dart';
import 'en_b4_settings.dart';
import 'en_b4_shared.dart';
import 'en_b5_editor1.dart';
import 'en_b5_editor2.dart';
import 'en_b5_editor3.dart';
import 'en_b5_editor4.dart';
import 'en_b5_editor5.dart';
import 'en_b5_resources.dart';
import 'en_b6_shell.dart';
import 'en_b7_errors.dart';
import 'en_b7_theme.dart';
import 'en_b8_editor.dart';
import 'en_b8_misc.dart';
import 'en_b8_publish.dart';
import 'en_b8_social.dart';
import 'en_b9_defaults.dart';
import 'en_b10_languages.dart';
import 'en_b11_holes.dart';
import 'en_b12_display.dart';
import 'en_b13_about.dart';
import 'en_core.dart';
import 'en_editor1.dart';
import 'en_editor2.dart';
import 'en_editor3.dart';
import 'en_editor4.dart';
import 'en_editor5.dart';
import 'en_export.dart';
import 'en_hub.dart';
import 'en_market.dart';
import 'en_misc.dart';
import 'en_profile.dart';
import 'en_quests.dart';
import 'en_resources.dart';
import 'en_shell.dart';
import 'en_social.dart';
import 'en_settings.dart';

/// Английский словарь, склеенный из модульных карт.
///
/// Модульные файлы (`en_<модуль>.dart`) не должны пересекаться по
/// ключам: за строку отвечает модуль, где она живёт, — иначе в grep
/// непонятно, какой перевод победит.
final Map<String, String> enStrings = {
  ...enCommon,
  ...enApp,
  ...enB2Analytics,
  ...enB2App,
  ...enB2AssetMarket,
  ...enB2Community,
  ...enB2Core,
  ...enB2Editor1,
  ...enB2Editor2,
  ...enB2Editor3,
  ...enB2Export,
  ...enB2Forums,
  ...enB2Game,
  ...enB2Hub,
  ...enB2Library,
  ...enB2Market,
  ...enB2Messages,
  ...enB2MusicLibrary,
  ...enB2PluginHost,
  ...enB2Plugins,
  ...enB2Profile,
  ...enB2Quests,
  ...enB2Resources,
  ...enB2Settings,
  ...enB2Shared,
  ...enB2Shell,
  ...enB2Undo,
  ...enB2Wall,
  ...enB3Titles,
  ...enB4Analytics,
  ...enB4Community,
  ...enB4Core,
  ...enB4Forums,
  ...enB4Hub,
  ...enB4Market,
  ...enB4Messages,
  ...enB4Plugins,
  ...enB4Profile,
  ...enB4Quests,
  ...enB4Settings,
  ...enB4Shared,
  ...enB5Editor1,
  ...enB5Editor2,
  ...enB5Editor3,
  ...enB5Editor4,
  ...enB5Editor5,
  ...enB5Resources,
  ...enB6Shell,
  ...enB7Errors,
  ...enB7Theme,
  ...enB8Publish,
  ...enB8Editor,
  ...enB8Social,
  ...enB8Misc,
  ...enB9Defaults,
  ...enB10Languages,
  ...enB11Holes,
  ...enB12Display,
  ...enB13About,
  ...enCore,
  ...enEditor1,
  ...enEditor2,
  ...enEditor3,
  ...enEditor4,
  ...enEditor5,
  ...enExport,
  ...enHub,
  ...enMarket,
  ...enMisc,
  ...enProfile,
  ...enQuests,
  ...enResources,
  ...enShell,
  ...enSocial,
  ...enSettings,
};

/// Формы множественного числа: lemma первой русской формы ->
/// `[one, other]`.
final Map<String, List<String>> enPlurals = {
  ...enCommonPlurals,
};
