import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class VersionCheckResult {
  final bool hasUpdate;
  final bool isCritical;
  final String latestVersion;
  final int latestBuild;
  final String downloadUrl;
  final String changelog;

  const VersionCheckResult({
    required this.hasUpdate,
    this.isCritical = false,
    this.latestVersion = '',
    this.latestBuild = 0,
    this.downloadUrl = '',
    this.changelog = '',
  });

  factory VersionCheckResult.fromJson(Map<String, dynamic> json) {
    return VersionCheckResult(
      hasUpdate: json['hasUpdate'] == true,
      isCritical: json['isCritical'] == true,
      latestVersion: json['latestVersion']?.toString() ?? '',
      latestBuild: json['latestBuild'] as int? ?? 0,
      downloadUrl: json['downloadUrl']?.toString() ?? '',
      changelog: json['changelog']?.toString() ?? '',
    );
  }
}

class VersionCheckService {
  static const String _checkUrl =
      'https://meander.illuminat.dev/api/app/version/check';

  static Future<VersionCheckResult> check() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
      final platform = _detectPlatform();

      debugPrint(
        '[VersionCheck] currentBuild=$currentBuild platform=$platform',
      );

      final uri = Uri.parse(_checkUrl).replace(
        queryParameters: {
          'build_number': currentBuild.toString(),
          'platform': platform,
        },
      );

      debugPrint('[VersionCheck] GET $uri');

      final response = await http
          .get(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'Meander/${packageInfo.version}',
            },
          )
          .timeout(const Duration(seconds: 8));

      debugPrint('[VersionCheck] statusCode=${response.statusCode}');
      debugPrint('[VersionCheck] body=${response.body}');

      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        debugPrint('[VersionCheck] parsed: hasUpdate=${data['hasUpdate']}');
        return VersionCheckResult.fromJson(data);
      }

      debugPrint('[VersionCheck] no update (bad status or empty body)');
      return const VersionCheckResult(hasUpdate: false);
    } catch (e, st) {
      debugPrint('[VersionCheck] ERROR: $e');
      debugPrint('[VersionCheck] STACK: $st');
      return const VersionCheckResult(hasUpdate: false);
    }
  }

  static String _detectPlatform() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'other';
  }
}
