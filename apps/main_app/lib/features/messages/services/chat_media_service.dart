import 'dart:convert';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/post_media_service.dart';
import 'package:canvas_app/core/services/device_identity.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Фото в чате: выбор до пяти штук и загрузка по одному.
///
/// Сжимает сервер (`chat_media.ts`): клиент может прислать любой файл, а
/// EXIF с геолокацией должен исчезнуть до публикации. Поэтому здесь не
/// трогаем пиксели — только просим у пикера исходник и проверяем вес.
class ChatMediaService {
  /// Предел альбома. Сервер режет по тому же числу, здесь — чтобы человек не
  /// выбирал шесть и не терял шестое молча.
  static const int albumLimit = 5;

  /// Тот же порог, что у сервера: 5 МБ. Крупнее — отказ с понятным текстом,
  /// а не 413 от nginx.
  static const int maxBytes = 5 * 1024 * 1024;

  static Future<List<XFile>> pickAlbum({int remaining = albumLimit}) async {
    if (remaining <= 0) return const [];
    final picked = await ImagePicker().pickMultiImage(
      limit: remaining,
      // Не пережимаем на клиенте в 0: сервер всё равно режет до 1600px, но
      // исходник нужен без потерь, иначе двойное сжатие видно на градиентах.
      imageQuality: 100,
      requestFullMetadata: false,
    );
    return picked.length > remaining ? picked.sublist(0, remaining) : picked;
  }

  /// Загрузка одного кадра. Бросок — только с готовым русским текстом: экран
  /// показывает его как есть.
  static Future<DmAttachment> upload(XFile picked, {http.Client? client}) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');
    if (token == null) {
      throw Exception(tr('Чтобы прикреплять фото, войди в аккаунт'));
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${AppConfig.apiUrl}/api/messages/upload-media'),
    )
      ..headers['Authorization'] = 'Bearer $token'
      ..headers.addAll(await DeviceIdentity.headers());
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        picked.path,
        contentType: imagePartType(picked.path),
      ),
    );

    final response = await (client ?? http.Client()).send(request);
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_failureReason(body, response.statusCode));
    }
    final decoded = jsonDecode(body);
    final raw = decoded is Map ? decoded['attachment'] : null;
    final parsed = DmAttachment.listFrom([raw]);
    if (parsed.isEmpty) {
      throw Exception(tr('Сервер не вернул ссылку на фото'));
    }
    return parsed.first;
  }

  static String _failureReason(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) {
        final message = (decoded['error'] as String).trim();
        if (message.isNotEmpty) return message;
      }
    } catch (_) {
      // nginx вернул HTML — покажем код.
    }
    return trf('Сервер не принял фото (код {p0})', {'p0': status});
  }
}