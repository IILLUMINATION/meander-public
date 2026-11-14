import 'dart:convert';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Фото в публикации. Один адрес на пост стены и на топик форума: топик — это
/// тот же `author_posts`, различать их на загрузке нечем.
class PostMediaUpload {
  /// Отменённый выбор молча возвращает `null`, отказ сервера приходит наружу
  /// готовой русской строкой: у экрана свой индикатор и своё сообщение.
  ///
  /// [client] подменяется в тесте: проверка заголовков multipart-части без
  /// живого сервера возможна только на подставном клиенте.
  static Future<String?> pickAndUpload({http.Client? client}) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // Просим пикер пересобрать фото: без этого iOS отдаёт оригинал в качестве
      // 100 и на полном разрешении, а 12-МП JPEG весит и 12 МБ — серверный
      // лимит 10 МБ такой файл не принимает. То же число, что у скриншотов
      // квеста.
      imageQuality: 85,
    );
    if (picked == null) return null;
    return upload(picked, client: client);
  }

  /// Загрузка уже выбранного файла. Вынесено из [pickAndUpload]: в тесте нет
  /// системной галереи, а проверить надо именно то, что улетает на сервер.
  static Future<String> upload(
    XFile picked, {
    http.Client? client,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');
    if (token == null) {
      throw Exception(tr('Чтобы прикреплять фото, войди в аккаунт'));
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${AppConfig.apiUrl}/api/author-walls/upload-media'),
    )..headers['Authorization'] = 'Bearer $token';
    // Тип части указываем явно: `package:http` без него ставит
    // `application/octet-stream`, а серверный fileFilter режет всё, что не
    // похоже на картинку, — фото не прикреплялось ни с одного устройства.
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
    final url = decoded is Map ? decoded['url']?.toString() : null;
    if (url == null || url.isEmpty) {
      throw Exception(tr('Сервер не вернул ссылку на фото'));
    }
    return url;
  }

  /// Причина отказа приходит с сервера по-русски — показываем её как есть,
  /// иначе человек видит «Сервер не принял фото (400)» и не понимает, что с
  /// файлом не так (ср. `_reasonFrom` у аватара).
  static String _failureReason(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) {
        final message = (decoded['error'] as String).trim();
        if (message.isNotEmpty) return message;
      }
    } catch (_) {
      // nginx-страница или пустое тело — вернём код.
    }
    return trf('Сервер не принял фото (код {p0})', {'p0': status});
  }
}

/// MIME-тип части multipart по расширению файла. Файл из галереи — всегда
/// jpg/png/webp/gif; неизвестное расширение отдаём как jpeg: сервер смотрит на
/// сигнатуру байт, а не на эту строку. Общий для стены, форума и чата: без
/// явного типа `package:http` ставит octet-stream, и сервер режет файл.
http.MediaType imagePartType(String filePath) {
  const byExtension = <String, String>{
    '.jpg': 'jpeg',
    '.jpeg': 'jpeg',
    '.png': 'png',
    '.webp': 'webp',
    '.gif': 'gif',
  };
  final subtype = byExtension[p.extension(filePath).toLowerCase()] ?? 'jpeg';
  return http.MediaType('image', subtype);
}

/// Картинка вставляется в то место, где курсор, — подпись к ней уже набрана, и
/// в конце текста она читалась бы как приписка.
void insertImageAtCursor(TextEditingController field, String url) {
  final snippet = '\n![Фото]($url)\n';
  final selection = field.selection;
  final start = selection.isValid ? selection.start : field.text.length;
  final end = selection.isValid ? selection.end : field.text.length;
  final text = field.text.replaceRange(start, end, snippet);
  field.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: start + snippet.length),
  );
}
