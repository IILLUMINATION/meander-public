import 'package:flutter/material.dart';

/// Раздел, к которому относится гайд. Подсказка-приглашение показывается
/// только для тех разделов, где гайд зарегистрирован.
enum GuideSection { library, market, hub }

/// Скелет «скриншота» под стрелками. Настоящий снимок меняется от темы,
/// языка и размера экрана; схема рисуется из темы и остаётся читаемой на
/// любом устройстве. Если у шага появится `imageAsset`, он заменит схему.
enum GuideShotKind { quests, editor, node, links, publish, market, hub, library }

/// Паспорт гайда: то, что известно до загрузки текста. Контент (заголовок,
/// статья, подписи шагов) лежит в `assets/guides/<id>/<язык>.json` и
/// `.md` — поэтому новые гайды не требуют правок словаря.
class GuideInfo {
  final String id;
  final GuideSection section;
  final String? videoAsset;
  final String? posterAsset;
  final IconData icon;
  final Color accent;

  const GuideInfo({
    required this.id,
    required this.section,
    required this.icon,
    required this.accent,
    this.videoAsset,
    this.posterAsset,
  });
}

/// Стрелка поверх схемы. Координаты нормализованы (0..1): шаг остаётся
/// на месте при любом размере карточки.
class GuideArrow {
  final Offset from;
  final Offset to;
  final String? label;

  const GuideArrow({required this.from, required this.to, this.label});
}

/// Подпись-пилюля поверх схемы: «Создать квест», «Переход» и т. п.
class GuideLabel {
  final String text;
  final Offset at;

  const GuideLabel({required this.text, required this.at});
}

class GuideShot {
  final GuideShotKind kind;
  final String title;
  final String caption;

  /// Подсветка области, к которой относится шаг. `null` — не затемнять фон.
  final Rect? focus;

  final List<GuideArrow> arrows;
  final List<GuideLabel> labels;

  /// Настоящий снимок экрана. Пока `null`: рисуем схему по `kind`.
  final String? imageAsset;

  const GuideShot({
    required this.kind,
    required this.title,
    required this.caption,
    this.focus,
    this.arrows = const [],
    this.labels = const [],
    this.imageAsset,
  });

  static GuideShot? fromJson(Map<String, dynamic> json) {
    final title = _text(json['title']);
    final caption = _text(json['caption']);
    if (title == null || caption == null) return null;

    final arrows = <GuideArrow>[];
    final rawArrows = json['arrows'];
    if (rawArrows is List) {
      for (final raw in rawArrows) {
        if (raw is! Map) continue;
        final from = _offset(raw['from']);
        final to = _offset(raw['to']);
        if (from == null || to == null) continue;
        arrows.add(
          GuideArrow(
            from: from,
            to: to,
            label: _text(raw['label']),
          ),
        );
      }
    }

    final labels = <GuideLabel>[];
    final rawLabels = json['labels'];
    if (rawLabels is List) {
      for (final raw in rawLabels) {
        if (raw is! Map) continue;
        final text = _text(raw['text']);
        final at = _offset(raw['at']);
        if (text == null || at == null) continue;
        labels.add(GuideLabel(text: text, at: at));
      }
    }

    return GuideShot(
      kind: _kind(json['kind']),
      title: title,
      caption: caption,
      focus: _rect(json['focus']),
      arrows: arrows,
      labels: labels,
      imageAsset: _text(json['image']),
    );
  }

  static GuideShotKind _kind(dynamic raw) {
    final name = _text(raw);
    if (name == null) return GuideShotKind.quests;
    for (final kind in GuideShotKind.values) {
      if (kind.name == name) return kind;
    }
    return GuideShotKind.quests;
  }
}

class GuideContent {
  final String languageCode;
  final String title;
  final String summary;
  final int minutes;
  final List<GuideShot> shots;
  final String article;

  const GuideContent({
    required this.languageCode,
    required this.title,
    required this.summary,
    required this.minutes,
    required this.shots,
    required this.article,
  });

  /// Минимальная валидация: без заголовка и описания гайд нечего показывать.
  /// Битые шаги пропускаем по одному — один плохой элемент не должен
  /// прятать весь гайд.
  static GuideContent? fromJson(
    Map<String, dynamic> json, {
    required String languageCode,
    required String article,
  }) {
    final title = _text(json['title']);
    final summary = _text(json['summary']);
    if (title == null || summary == null) return null;

    final shots = <GuideShot>[];
    final rawShots = json['shots'];
    if (rawShots is List) {
      for (final raw in rawShots) {
        if (raw is! Map) continue;
        final shot = GuideShot.fromJson(Map<String, dynamic>.from(raw));
        if (shot != null) shots.add(shot);
      }
    }

    final minutes = json['minutes'];
    return GuideContent(
      languageCode: languageCode,
      title: title,
      summary: summary,
      minutes: minutes is num ? minutes.toInt().clamp(1, 120) : 3,
      shots: shots,
      article: article.trim(),
    );
  }
}

String? _text(dynamic raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  return text.isEmpty ? null : text;
}

double? _unit(dynamic raw) {
  if (raw is! num) return null;
  return raw.toDouble().clamp(0.0, 1.0);
}

Offset? _offset(dynamic raw) {
  if (raw is! List || raw.length < 2) return null;
  final x = _unit(raw[0]);
  final y = _unit(raw[1]);
  if (x == null || y == null) return null;
  return Offset(x, y);
}

Rect? _rect(dynamic raw) {
  if (raw is! List || raw.length < 4) return null;
  final x = _unit(raw[0]);
  final y = _unit(raw[1]);
  final w = _unit(raw[2]);
  final h = _unit(raw[3]);
  if (x == null || y == null || w == null || h == null) return null;
  return Rect.fromLTWH(x, y, w, h);
}
