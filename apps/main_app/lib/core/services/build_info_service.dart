import 'dart:io';

import 'package:path/path.dart' as p;

/// Ветка и коммит git, из которых собрано запущенное приложение.
///
/// Источники по приоритету:
/// 1. `--dart-define=GIT_BRANCH=...` / `--dart-define=GIT_COMMIT=...` —
///    единственный способ узнать это на Android/iOS и в релизном бандле.
/// 2. На десктопе — чтение `.git` вверх по дереву от текущего каталога и от
///    каталога исполняемого файла. Только файлы: без процессов, сети и git.
/// 3. `unknown`, если ничего не найдено.
class AppBuildInfo {
  final String branch;
  final String commit;

  const AppBuildInfo({required this.branch, required this.commit});

  static const AppBuildInfo unknown = AppBuildInfo(
    branch: 'unknown',
    commit: 'unknown',
  );

  /// Есть ли хоть что-то, что имеет смысл показать пользователю.
  bool get isKnown => branch != unknown.branch || commit != unknown.commit;
}

class AppBuildInfoService {
  AppBuildInfoService._();

  static const String _definedBranch = String.fromEnvironment('GIT_BRANCH');
  static const String _definedCommit = String.fromEnvironment('GIT_COMMIT');
  static const int _shortCommitLength = 7;
  static final RegExp _hashPattern = RegExp(r'^[0-9a-fA-F]{7,40}$');

  static AppBuildInfo load({
    String? defineBranch,
    String? defineCommit,
    Iterable<Directory>? searchFrom,
    bool? isDesktop,
  }) {
    final branch = (defineBranch ?? _definedBranch).trim();
    final commit = (defineCommit ?? _definedCommit).trim();
    if (branch.isNotEmpty || commit.isNotEmpty) {
      return AppBuildInfo(
        branch: branch.isEmpty ? AppBuildInfo.unknown.branch : branch,
        commit: commit.isEmpty ? AppBuildInfo.unknown.commit : _short(commit),
      );
    }

    final desktop = isDesktop ?? _isDesktop;
    if (!desktop) return AppBuildInfo.unknown;

    for (final start in searchFrom ?? _defaultSearchRoots()) {
      final gitDir = _findGitDir(start);
      if (gitDir == null) continue;
      final info = _readHead(gitDir);
      if (info != null) return info;
    }
    return AppBuildInfo.unknown;
  }

  static bool get _isDesktop =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  static List<Directory> _defaultSearchRoots() {
    final roots = <Directory>[Directory.current];
    try {
      final executable = Platform.resolvedExecutable;
      if (executable.isNotEmpty) {
        roots.add(File(executable).parent);
      }
    } catch (_) {
      // На некоторых платформах resolvedExecutable может быть пустым.
    }
    return roots;
  }

  static String _short(String commit) {
    final trimmed = commit.trim();
    if (trimmed.length <= _shortCommitLength) return trimmed;
    return trimmed.substring(0, _shortCommitLength);
  }

  static Directory? _findGitDir(Directory start) {
    try {
      var dir = start.absolute;
      while (true) {
        final dotGit = p.join(dir.path, '.git');
        final asDirectory = Directory(dotGit);
        if (asDirectory.existsSync()) return _resolveGitDir(asDirectory);
        final asFile = File(dotGit);
        if (asFile.existsSync()) return _resolveGitDir(asFile);

        final parent = dir.parent;
        if (parent.path == dir.path) return null;
        dir = parent;
      }
    } catch (_) {
      return null;
    }
  }

  /// `.git` может быть каталогом или файлом `gitdir: ...` (linked worktree).
  static Directory? _resolveGitDir(FileSystemEntity entity) {
    try {
      if (entity is Directory) return entity;
      final firstLine = File(entity.path).readAsLinesSync().first;
      if (!firstLine.startsWith('gitdir:')) return null;
      final raw = firstLine.substring('gitdir:'.length).trim();
      if (raw.isEmpty) return null;
      final resolved = p.isAbsolute(raw)
          ? raw
          : p.normalize(p.join(p.dirname(entity.path), raw));
      final dir = Directory(resolved);
      return dir.existsSync() ? dir : null;
    } catch (_) {
      return null;
    }
  }

  static AppBuildInfo? _readHead(Directory gitDir) {
    try {
      final head = File(p.join(gitDir.path, 'HEAD')).readAsStringSync().trim();
      if (head.isEmpty) return null;

      if (head.startsWith('ref:')) {
        final ref = head.substring(4).trim();
        if (ref.isEmpty) return null;
        final commit = _readRef(gitDir, ref);
        if (commit == null) return null;
        return AppBuildInfo(branch: _branchName(ref), commit: _short(commit));
      }

      if (_hashPattern.hasMatch(head)) {
        return AppBuildInfo(branch: 'detached', commit: _short(head));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _branchName(String ref) {
    const headsPrefix = 'refs/heads/';
    return ref.startsWith(headsPrefix)
        ? ref.substring(headsPrefix.length)
        : ref;
  }

  static String? _readRef(Directory gitDir, String ref) {
    final commonDir = _commonDir(gitDir);
    final dirs = <Directory>[commonDir];
    if (commonDir.path != gitDir.path) dirs.add(gitDir);

    for (final dir in dirs) {
      try {
        final loose = File(p.joinAll([dir.path, ...ref.split('/')]));
        if (loose.existsSync()) {
          final value = loose.readAsStringSync().trim();
          if (_hashPattern.hasMatch(value)) return value;
        }
      } catch (_) {
        // Битая или недоступная ссылка — пробуем следующий источник.
      }
    }

    try {
      final packed = File(p.join(commonDir.path, 'packed-refs'));
      if (!packed.existsSync()) return null;
      for (final line in packed.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty ||
            trimmed.startsWith('#') ||
            trimmed.startsWith('^')) {
          continue;
        }
        final space = trimmed.indexOf(' ');
        if (space <= 0) continue;
        if (trimmed.substring(space + 1).trim() != ref) continue;
        final value = trimmed.substring(0, space).trim();
        if (_hashPattern.hasMatch(value)) return value;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// У linked worktree ссылки лежат в общем `.git`, путь к нему — в `commondir`.
  static Directory _commonDir(Directory gitDir) {
    try {
      final marker = File(p.join(gitDir.path, 'commondir'));
      if (!marker.existsSync()) return gitDir;
      final raw = marker.readAsStringSync().trim();
      if (raw.isEmpty) return gitDir;
      final resolved = p.isAbsolute(raw)
          ? raw
          : p.normalize(p.join(gitDir.path, raw));
      final dir = Directory(resolved);
      return dir.existsSync() ? dir : gitDir;
    } catch (_) {
      return gitDir;
    }
  }
}
