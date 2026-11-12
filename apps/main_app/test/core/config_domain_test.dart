// Домен должен жить в одном месте. Тест держит два свойства:
//
// 1) адреса, которые приложение показывает и открывает, собираются из
//    `AppConfig.vpsApiBaseUrl` (а не из литералов по экранам);
// 2) в `lib/` нет литералов текущего домена вне явных исключений — иначе
//    при следующем переезде половина ссылок снова останется на мёртвом
//    хосте (так уже случилось с `meander.sbs`: картинки в сообществе не
//    грузились, потому что ссылки лежали в тексте постов).
//
// Скан исходников, как и в `l10n_guard_test.dart`, — архитектурный контроль:
// он ловит новую копию адреса сразу, а не на проде.

import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Файлы, где домен жить обязан или где он исторический.
const _allowedFiles = {
  // Единственный источник адреса (+ legacy-хосты, которые остаются
  // карточками в старых постах).
  'lib/core/config.dart',
  'lib/shared/entity_links/meander_entity.dart',
  // Список снятых зеркал — по ним ругается лог.
  'lib/core/services/mirror_registry.dart',
};

const _allowedDirectories = [
  // Переводы: в тексте есть плейсхолдер, но исторические фразы не домен.
  'lib/core/l10n/dictionaries/',
];

void main() {
  test('адрес бэкенда — валидный https без хвостового слэша', () {
    final uri = Uri.parse(AppConfig.vpsApiBaseUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, isNotEmpty);
    expect(AppConfig.vpsApiBaseUrl.endsWith('/'), isFalse,
        reason: 'слэш в конце даёт //share и //uploads');
  });

  test('подпись хоста и ссылки «поделиться» выводятся из адреса', () {
    expect(AppConfig.siteHost, Uri.parse(AppConfig.vpsApiBaseUrl).host);
    expect(
      AppConfig.shareUrl('quest', 'abc'),
      '${AppConfig.vpsApiBaseUrl}/share/quest/abc',
    );
  });

  test('в lib/ нет литералов домена вне исключений', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue);
    final needle = Uri.parse(AppConfig.vpsApiBaseUrl).host;
    final offenders = <String>[];

    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final path = file.path.replaceAll(r'\', '/');
      if (_allowedFiles.contains(path)) continue;
      if (_allowedDirectories.any(path.startsWith)) continue;
      final text = file.readAsStringSync();
      if (text.contains(needle)) offenders.add(path);
    }

    expect(
      offenders,
      isEmpty,
      reason: 'домен вписан в код — используйте AppConfig.vpsApiBaseUrl '
          'или AppConfig.siteHost: ${offenders.join(', ')}',
    );
  });
}