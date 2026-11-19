// @адреса профилей и каналов: сервер может прислать null (старая версия или
// адрес не задан), и это не должно превращаться в «@null» в шапке.

import 'package:canvas_app/features/channels/models/channel_models.dart';
import 'package:canvas_app/models/user_profile_model.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _profileJson({Object? username}) => {
  'id': 'u-1',
  'full_name': 'Аня Петрова',
  'created_at': '2026-11-14T10:00:00.000Z',
  'username': username,
};

void main() {
  test('username профиля приходит и обрезается', () {
    final profile = UserProfile.fromJson(_profileJson(username: '  mnd_dev '));
    expect(profile.username, 'mnd_dev');
  });

  test('пустой или отсутствующий username — это null', () {
    expect(UserProfile.fromJson(_profileJson()).username, isNull);
    expect(UserProfile.fromJson(_profileJson(username: '  ')).username, isNull);
    expect(UserProfile.fromJson(_profileJson(username: 42)).username, isNull);
  });

  test('slug канала читается, пустой — null, copyWith не теряет его', () {
    final channel = Channel.fromJson({
      'id': 'c-1',
      'title': 'Новости',
      'slug': 'meander',
    });
    expect(channel.slug, 'meander');
    expect(channel.copyWith(subscribersCount: 5).slug, 'meander');

    final noSlug = Channel.fromJson({'id': 'c-2', 'title': 'Клуб', 'slug': ''});
    expect(noSlug.slug, isNull);
  });
}
