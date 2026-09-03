// Pins what tool/claude-guard.sh refuses (exit 2) and allows (exit 0). The
// guard is a Claude Code PreToolUse hook; it reads the tool input as JSON on
// stdin, so the test feeds it the same shape. Requires `bash` and `jq`.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

Future<int> guard(String command) async {
  final script = File('${_repoRoot().path}/tool/claude-guard.sh');
  final process = await Process.start('bash', <String>[script.path]);
  process.stdin.write(
    jsonEncode(<String, Object?>{
      'tool_input': <String, Object?>{'command': command},
    }),
  );
  await process.stdin.close();
  await process.stderr.drain<void>();
  return process.exitCode;
}

Directory _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/tool/claude-guard.sh').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('run inside the repository');
    dir = parent;
  }
  return dir;
}

void main() {
  // The forbidden spellings are built from parts so that this file itself
  // never contains one on a single line.
  const dd = '--';
  const ci = 'CI';
  const ex = 'EXAMPLE';
  final refused = <String>[
    'git commit ${dd}no-verify -m x',
    'git commit ${dd}no-ver -m x',
    'git commit -n -m x',
    'git commit -am x -n',
    'git push ${dd}force origin main',
    'git push ${dd}forc origin main',
    'git push ${dd}force-with-lease origin main',
    'git push -f origin main',
    'git push -fu origin main',
    'git push origin +main',
    'git push origin :old-branch',
    'git push origin ${dd}delete old-branch',
    'git filter-repo ${dd}replace-text x',
    'git add .',
    'git add ./',
    'git add -A',
    'git add ${dd}all',
    'git add :/',
    'git add *',
    'git reset ${dd}hard HEAD~1',
    'git reset ${dd}har',
    'git tag v0.1.0',
    'git tag -a v0.1.0 -m x',
    'git tag -l; git push -f origin main',
    'git branch -D topic',
    'git branch -d topic',
    'git -c core.hooksPath=/dev/null commit -m x',
    'git config core.hooksPath x',
    'GIT_DIR=/tmp/x git commit -m y',
    'export SKIP_${ci}_GATE=1; git push',
    'SKIP_${ex}_GATE=1 tool/gate.sh',
    'git checkout $dd lib/main.dart',
    'git checkout lib/main.dart',
    'git checkout HEAD $dd lib/main.dart',
    'git restore lib/main.dart',
    'git restore ${dd}worktree lib/main.dart',
  ];
  final allowed = <String>[
    'git status --porcelain',
    'git log --oneline | head',
    'git diff -- rules/security.md',
    'git add tool/gate.sh rules/index.md',
    'git commit -m "Add the guard test"',
    'git commit -F /tmp/message.txt',
    'git push -u origin main',
    'git pull --rebase',
    'git stash -u && tool/gate.sh; git stash pop',
    'git tag -l',
    'git tag --list',
    'git restore --staged docs/errors.md',
    'git checkout -b topic',
    'dart test --reporter=compact',
    'flutter run -d linux --dart-define=YYT_OFFLINE_AUTOSTART=true',
    'gh run list --limit 3',
  ];

  for (final command in refused) {
    test('refuses: $command', () async => expect(await guard(command), 2));
  }
  for (final command in allowed) {
    test('allows: $command', () async => expect(await guard(command), 0));
  }
}
