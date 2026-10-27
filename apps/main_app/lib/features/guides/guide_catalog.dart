import 'package:flutter/material.dart';

import 'models/guide.dart';

/// Каталог гайдов, вшитых в приложение. Тексты и шаги лежат рядом, в
/// `assets/guides/<id>/`; здесь — только паспорт и порядок.
///
/// Новый раздел подключается одной записью: попап в разделе ищет гайд по
/// `GuideSection`, а экран «Гайды» показывает всё, что есть в списке.
class GuideCatalog {
  GuideCatalog._();

  static const List<GuideInfo> _guides = [
    GuideInfo(
      id: 'create_quest',
      section: GuideSection.library,
      icon: Icons.auto_stories_rounded,
      accent: Color(0xFFFFB300),
      videoAsset: 'assets/guides/create_quest/intro.mp4',
      posterAsset: 'assets/guides/create_quest/intro_poster.png',
    ),
    GuideInfo(
      id: 'market',
      section: GuideSection.market,
      icon: Icons.storefront_rounded,
      accent: Color(0xFF7C4DFF),
    ),
    GuideInfo(
      id: 'hub',
      section: GuideSection.hub,
      icon: Icons.inventory_2_rounded,
      accent: Color(0xFF26A69A),
    ),
  ];

  static List<GuideInfo> get all => List.unmodifiable(_guides);

  static GuideInfo? forSection(GuideSection section) {
    for (final guide in _guides) {
      if (guide.section == section) return guide;
    }
    return null;
  }

  static GuideInfo? byId(String id) {
    for (final guide in _guides) {
      if (guide.id == id) return guide;
    }
    return null;
  }
}
