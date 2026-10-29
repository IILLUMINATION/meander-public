import 'dart:io';

import 'package:canvas_app/core/services/build_info_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mnd_build_info_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Directory createRepo({
    required Directory root,
    required String head,
    String? ref,
    String? hash,
    String? packedRefs,
  }) {
    final git = Directory(p.join(root.path, '.git'))..createSync();
    File(p.join(git.path, 'HEAD')).writeAsStringSync('$head\n');
    if (ref != null && hash != null) {
      final refFile = File(p.joinAll([git.path, ...ref.split('/')]))
        ..createSync(recursive: true);
      refFile.writeAsStringSync('$hash\n');
    }
    if (packedRefs != null) {
      File(p.join(git.path, 'packed-refs')).writeAsStringSync(packedRefs);
    }
    return git;
  }

  AppBuildInfo loadFrom(Directory start) => AppBuildInfoService.load(
    defineBranch: '',
    defineCommit: '',
    searchFrom: [start],
    isDesktop: true,
  );

  test('читает ветку и короткий коммит из обычного .git', () {
    final repo = Directory(p.join(temp.path, 'repo'))..createSync();
    createRepo(
      root: repo,
      head: 'ref: refs/heads/ui-update',
      ref: 'refs/heads/ui-update',
      hash: 'ab9b92c99d78310ad3b3108ce2591e962c4d2f6f',
    );
    final appDir = Directory(p.join(repo.path, 'apps', 'main_app'))
      ..createSync(recursive: true);

    final info = loadFrom(appDir);

    expect(info.branch, 'ui-update');
    expect(info.commit, 'ab9b92c');
    expect(info.isKnown, isTrue);
  });

  test('detached HEAD показывает detached и коммит', () {
    final repo = Directory(p.join(temp.path, 'repo'))..createSync();
    createRepo(root: repo, head: 'deadbeefcafebabe1234567890abcdef12345678');

    final info = loadFrom(repo);

    expect(info.branch, 'detached');
    expect(info.commit, 'deadbee');
  });

  test('linked worktree: .git-файл и commondir', () {
    final repo = Directory(p.join(temp.path, 'repo'))..createSync();
    final git = createRepo(
      root: repo,
      head: 'ref: refs/heads/main',
      ref: 'refs/heads/main',
      hash: '4f5ea0fc7fe5f5a0062b68fa198b33ef6f4d6ee7',
    );
    final worktreeGit = Directory(p.join(git.path, 'worktrees', 'wt'))
      ..createSync(recursive: true);
    File(
      p.join(worktreeGit.path, 'HEAD'),
    ).writeAsStringSync('ref: refs/heads/main\n');
    File(p.join(worktreeGit.path, 'commondir')).writeAsStringSync('../..\n');

    final worktree = Directory(p.join(temp.path, 'wt'))..createSync();
    File(
      p.join(worktree.path, '.git'),
    ).writeAsStringSync('gitdir: ${worktreeGit.path}\n');

    final info = loadFrom(worktree);

    expect(info.branch, 'main');
    expect(info.commit, '4f5ea0f');
  });

  test('читает ссылку из packed-refs, если loose-файла нет', () {
    final repo = Directory(p.join(temp.path, 'repo'))..createSync();
    createRepo(
      root: repo,
      head: 'ref: refs/heads/main',
      packedRefs: '4f5ea0fc7fe5f5a0062b68fa198b33ef6f4d6ee7 refs/heads/main\n',
    );

    final info = loadFrom(repo);

    expect(info.branch, 'main');
    expect(info.commit, '4f5ea0f');
  });

  test('dart-define перекрывает поиск по .git', () {
    final info = AppBuildInfoService.load(
      defineBranch: 'feature/about',
      defineCommit: 'abcdef1234567890',
      searchFrom: const [],
      isDesktop: false,
    );

    expect(info.branch, 'feature/about');
    expect(info.commit, 'abcdef1');
  });

  test('без .git и define значения unknown', () {
    final info = loadFrom(temp);

    expect(info.isKnown, isFalse);
    expect(info.branch, 'unknown');
    expect(info.commit, 'unknown');
  });
}
