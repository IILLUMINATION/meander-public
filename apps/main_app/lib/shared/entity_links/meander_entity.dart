/// Ссылки на свои же сущности внутри пользовательского текста.
///
/// Человек вставляет в пост, обзор, описание квеста или личное сообщение то,
/// что уже есть в приложении: `https://meander.illuminat.dev/share/quest/<id>`,
/// `meander://profile/<id>` или голый uuid. Раньше такое либо уводило в
/// браузер, поскольку markdown-ссылка открывалась системным viewer, либо
/// лежало серой строкой символов, по которой нельзя нажать. Здесь решается
/// первая половина: текст режется на куски «слова» и «ссылка на сущность», а
/// рисует их `entity_ref_card.dart`.
library;

import 'package:canvas_app/core/config.dart';

enum MeanderEntityKind { quest, profile, post, unknown }

/// Найденная ссылка. Тип известен из адреса; для голого uuid его не знает
/// никто, и тип дотягивает резолвер в `entity_ref_card.dart` — угадать по
/// строке невозможно, квест это, человек или пост.
class MeanderEntity {
  const MeanderEntity({required this.kind, required this.id});

  final MeanderEntityKind kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is MeanderEntity && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'MeanderEntity(${kind.name}, $id)';
}

/// Кусок исходного текста: обычные слова или ссылка.
class MeanderSegment {
  const MeanderSegment.text(this.text) : entity = null;
  const MeanderSegment.entity(this.entity) : text = '';

  final String text;
  final MeanderEntity? entity;

  bool get isEntity => entity != null;
}

final RegExp _uuid = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
  caseSensitive: false,
);

/// Домены, с которых начинали и переезжали. Ссылки из старых постов и
/// сообщений должны оставаться карточками, поэтому история хостов живёт
/// здесь, а действующий адрес приходит из конфига: при очередном переезде
/// достаточно пополнить этот список, а не искать регулярки по коду.
const List<String> legacyMeanderHosts = [
  'meander.sbs',
  'backend.meander.sbs',
  'meander.illuminat.dev',
];

/// Хосты, которые принадлежат приложению. Без этого чужой
/// `example.com/share/quest/<uuid>` тоже превратился бы в карточку.
final String _hosts = [
  ...legacyMeanderHosts,
  AppConfig.vpsApiBaseUrl,
  ...AppConfig.defaultMirrorUrls,
  AppConfig.apiUrl,
]
    .map((u) => u.replaceFirst(RegExp(r'^https?://'), ''))
    .map(RegExp.escape)
    .toSet()
    .join('|');

/// Общий кусок адреса: `хост/share/<тип>/<uuid>`. `before`/`after` — рамки
/// конкретного вида ссылки (скобки markdown-ссылки или ничего).
String _sharePattern({required String before, required String after}) =>
    '$before(?:https?://)?($_hosts)/share/(quest|profile|post)/'
    '(${_uuid.pattern})$after';

/// `[вот этот квест](https://meander.illuminat.dev/share/quest/<id>)` — подпись
/// человека остаётся подписью, карточка встаёт вместо адреса.
final RegExp _markdownLink = RegExp(
  _sharePattern(before: r'\[([^\]\n]*)\]\(\s*', after: r'\s*\)'),
  caseSensitive: false,
);

/// Адрес без обёртки markdown: с протоколом и без него.
final RegExp _shareUrl = RegExp(
  _sharePattern(before: '', after: ''),
  caseSensitive: false,
);

/// Собственная схема приложения — её в браузер не отправляют. `share/` внутри
/// схемы не опечатка: страницы `/share/quest/<id>` дают кнопку «открыть в
/// приложении» именно с `meander://share/quest/<id>`, и `DeepLinkService` этот
/// сегмент срезает. Без него вставленная из шаринга ссылка оставалась серой
/// строкой — uuid в ней голым тоже не считается, он стоит после слэша.
final RegExp _schemeUrl = RegExp(
  'meander://(?:share/)?(quest|profile|post)/(${_uuid.pattern})',
  caseSensitive: false,
);

class _Hit {
  const _Hit(this.start, this.end, this.kind, this.id, this.label);

  final int start;
  final int end;
  final MeanderEntityKind kind;
  final String id;

  /// Подпись markdown-ссылки: человек писал «вот этот квест», и эти слова его
  /// сообщения, а не адрес, — выбрасывать их никто не просил.
  final String label;
}

MeanderEntityKind _kindOf(String? word) => switch (word?.toLowerCase()) {
  'quest' => MeanderEntityKind.quest,
  'profile' => MeanderEntityKind.profile,
  'post' => MeanderEntityKind.post,
  _ => MeanderEntityKind.unknown,
};

/// Голый uuid живёт не только в ссылках: ресурсы квеста (картинки, звуки)
/// тоже называются uuid, и путь `assets/1f2e….png` — не сущность сообщества.
/// Карточка поверх пути выглядела бы поломкой, поэтому соседство проверяется.
bool _isBareUuidMatch(String source, int start, int end) {
  final before = start > 0 ? source[start - 1] : '';
  final after = end < source.length ? source[end] : '';
  if (before == '/' || after == '/' || after == '.') return false;
  if (before.isNotEmpty && RegExp(r'[A-Za-z0-9_-]').hasMatch(before)) {
    return false;
  }
  return true;
}

List<_Hit> _hits(String source) {
  return [
    for (final match in _markdownLink.allMatches(source))
      _Hit(
        match.start,
        match.end,
        _kindOf(match.group(3)),
        match.group(4)!.toLowerCase(),
        match.group(1)!.trim(),
      ),
    for (final match in _shareUrl.allMatches(source))
      _Hit(
        match.start,
        match.end,
        _kindOf(match.group(2)),
        match.group(3)!.toLowerCase(),
        '',
      ),
    for (final match in _schemeUrl.allMatches(source))
      _Hit(
        match.start,
        match.end,
        _kindOf(match.group(1)),
        match.group(2)!.toLowerCase(),
        '',
      ),
    for (final match in _uuid.allMatches(source))
      if (_isBareUuidMatch(source, match.start, match.end))
        _Hit(
          match.start,
          match.end,
          MeanderEntityKind.unknown,
          match.group(0)!.toLowerCase(),
          '',
        ),
  ];
}

/// Режет текст на куски. Самый левый матч выигрывает, перекрывающиеся —
/// отбрасываются: markdown-ссылка содержит в себе обычный адрес, и из одного
/// вложения не должно получаться две карточки.
List<MeanderSegment> splitMeanderEntities(String source) {
  if (source.isEmpty) return const [];

  final hits = _hits(source)
    ..sort((a, b) =>
        a.start != b.start ? a.start.compareTo(b.start) : b.end.compareTo(a.end));

  final segments = <MeanderSegment>[];
  var cursor = 0;
  for (final hit in hits) {
    if (hit.start < cursor || hit.id.isEmpty) continue;
    if (hit.start > cursor) {
      segments.add(MeanderSegment.text(source.substring(cursor, hit.start)));
    }
    if (hit.label.isNotEmpty) {
      segments.add(MeanderSegment.text('${hit.label} '));
    }
    segments.add(
      MeanderSegment.entity(
        MeanderEntity(kind: hit.kind, id: hit.id),
      ),
    );
    cursor = hit.end;
  }
  if (cursor < source.length) {
    segments.add(MeanderSegment.text(source.substring(cursor)));
  }
  return segments;
}

/// Есть ли в тексте на что строить карточку — экраны сверяются с этим, чтобы
/// не тащить rich-обвязку там, где ссылок нет.
bool hasMeanderEntity(String source) =>
    source.isNotEmpty && splitMeanderEntities(source).any((s) => s.isEntity);

final RegExp _ownHostPrefix = RegExp(
  '^(?:https?://)?(?:$_hosts)(?:/|\$)',
  caseSensitive: false,
);

/// Ссылка ведёт на Meander? Нужна там, где карточка не строится, а уводить
/// человека в браузер ради своей же страницы тем более нельзя.
bool pointsToMeander(String url) {
  final trimmed = url.trim();
  return trimmed.toLowerCase().startsWith('meander://') ||
      _ownHostPrefix.hasMatch(trimmed);
}
