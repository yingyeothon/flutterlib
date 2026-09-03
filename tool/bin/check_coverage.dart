// Runs each package's own test suite with coverage and gates it on that
// suite alone: line >= 80 %, branch >= 70 % (COVERAGE_LINE_MIN /
// COVERAGE_BRANCH_MIN override). The aggregate is not the interesting number:
// a package with no tests of its own still shows up covered because another
// package's suite walks through it, so every package has to carry its own
// weight.
//
// Integration tests (`-x integration`) are excluded: they exercise the real
// transport against a loopback server, and the pure suite must reach the
// floor without them.
//
//   dart run tool/bin/check_coverage.dart [package-dir ...]
import 'dart:io';

import 'package:yyt_tool/src/lcov.dart';

Future<void> main(List<String> args) async {
  final root = _repoRoot();
  final lineMin =
      double.tryParse(Platform.environment['COVERAGE_LINE_MIN'] ?? '') ?? 80;
  final branchMin =
      double.tryParse(Platform.environment['COVERAGE_BRANCH_MIN'] ?? '') ?? 70;

  final packages = args.isNotEmpty
      ? args.map((a) => Directory(a)).toList()
      : (Directory('${root.path}/packages')
            .listSync()
            .whereType<Directory>()
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)));

  var failed = false;
  print('${'package'.padRight(34)} ${'line'.padRight(10)} branch');
  for (final dir in packages) {
    final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final lcov = File('${dir.path}/coverage/lcov.info');
    if (lcov.existsSync()) lcov.deleteSync();
    final result = await Process.run('dart', <String>[
      'test',
      '--coverage-path=coverage/lcov.info',
      '--branch-coverage',
      '-x',
      'integration',
      '--reporter',
      'failures-only',
    ], workingDirectory: dir.path);
    if (result.exitCode != 0) {
      stdout.write(result.stdout);
      stderr.write(result.stderr);
      print('${name.padRight(34)} TESTS FAILED');
      failed = true;
      continue;
    }
    if (!lcov.existsSync()) {
      print('${name.padRight(34)} NO REPORT (no tests?)');
      failed = true;
      continue;
    }
    final totals = sumLcov(
      lcov.readAsStringSync(),
      // Only this package's own lib/: the workspace resolves siblings to
      // their source, and their lines would otherwise count here too.
      include: (path) => _isOwnLib(path, dir),
    );
    final line = totals.linePercent;
    final branch = totals.branchPercent;
    final lineOk = line >= lineMin;
    final branchOk = branch == null || branch >= branchMin;
    final mark = lineOk && branchOk ? '' : '   <-- below floor';
    print(
      '${name.padRight(34)} ${line.toStringAsFixed(1).padRight(10)} '
      '${branch == null ? 'n/a' : branch.toStringAsFixed(1)}$mark',
    );
    if (!lineOk || !branchOk) failed = true;
  }
  if (failed) {
    print('coverage: floor is line $lineMin / branch $branchMin per package');
    exit(1);
  }
  print('coverage: every package covers itself');
}

bool _isOwnLib(String sfPath, Directory package) {
  // dart test writes `SF:` as a path relative to the package (lib/...) or,
  // for workspace siblings, as a path that leaves the package.
  final normalized = sfPath.replaceAll('\\', '/');
  if (normalized.startsWith('lib/')) return true;
  final abs = Directory(package.path).absolute.path.replaceAll('\\', '/');
  return normalized.startsWith('$abs/lib/');
}

Directory _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync() ||
      !Directory('${dir.path}/packages').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln('check_coverage: run from inside the repository');
      exit(2);
    }
    dir = parent;
  }
  return dir;
}
