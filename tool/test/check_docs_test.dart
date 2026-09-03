import 'dart:io';

import 'package:test/test.dart';
import 'package:yyt_tool/src/check_docs.dart';
import 'package:yyt_tool/src/lcov.dart';

/// A minimal repository that passes every check. Each test breaks one thing
/// and expects exactly that failure, so a check that silently stops firing
/// is caught here.
final class Fixture {
  Fixture(this.root);

  static Fixture create() {
    final root = Directory.systemTemp.createTempSync('check_docs_');
    final f = Fixture(root);
    f.write('pubspec.yaml', '''
name: fixture
publish_to: none
environment:
  sdk: ^3.13.0
workspace:
  - packages/yingyeothon_alpha
  - packages/yingyeothon_beta
  - tool
''');
    f.write(
      'tool/pubspec.yaml',
      'name: t\npublish_to: none\nresolution: workspace\n',
    );
    f.write('README.md', '''
# fixture

| Package | Description |
| --- | --- |
| [yingyeothon_alpha](packages/yingyeothon_alpha) | a |
| [yingyeothon_beta](packages/yingyeothon_beta) | b |

```mermaid
graph LR
  yingyeothon_beta --> yingyeothon_alpha
```

See [the guide](docs/README.md).
''');
    f.write(
      'packages/yingyeothon_alpha/pubspec.yaml',
      'name: yingyeothon_alpha\nversion: 0.1.0\nresolution: workspace\n',
    );
    f.write(
      'packages/yingyeothon_alpha/lib/yingyeothon_alpha.dart',
      "export 'src/a.dart' show Alpha, alphaCount;\n",
    );
    f.write('packages/yingyeothon_alpha/README.md', '''
# yingyeothon_alpha

Purpose.

```mermaid
flowchart LR
  a --> b
```

## Install

Add `yingyeothon_alpha`.

## Public API

`Alpha` and `alphaCount`.
''');
    f.write(
      'packages/yingyeothon_beta/pubspec.yaml',
      'name: yingyeothon_beta\nversion: 0.1.0\nresolution: workspace\ndependencies:\n  yingyeothon_alpha: ^0.1.0\n',
    );
    f.write(
      'packages/yingyeothon_beta/lib/yingyeothon_beta.dart',
      "export 'src/b.dart' show Beta;\n",
    );
    f.write('packages/yingyeothon_beta/README.md', '''
# yingyeothon_beta

Purpose.

```mermaid
sequenceDiagram
  A->>B: hi
```

## Install

Add `yingyeothon_beta`.

## Public API

`Beta`.
''');
    f.write('docs/README.md', '''
# Guide

- [Errors](errors.md)
- [Trouble](troubleshooting.md#a-symptom)
''');
    f.write('docs/errors.md', '''
# Errors

Close codes: `4000`, `4001`.
''');
    f.write('docs/troubleshooting.md', '''
# Troubleshooting

## A symptom

Do this.
''');
    f.write('examples/README.md', '- [demo](demo/)\n');
    f.write('examples/demo/pubspec.yaml', 'name: demo_app\npublish_to: none\n');
    return f;
  }

  final Directory root;

  void write(String path, String content) {
    final file = File('${root.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String read(String path) => File('${root.path}/$path').readAsStringSync();

  void edit(String path, String from, String to) {
    final text = read(path);
    if (!text.contains(from)) throw StateError('fixture $path lacks: $from');
    write(path, text.replaceFirst(from, to));
  }

  List<String> run() => checkDocs(root);

  void dispose() => root.deleteSync(recursive: true);
}

void main() {
  late Fixture fx;
  setUp(() => fx = Fixture.create());
  tearDown(() => fx.dispose());

  test('the fixture is green', () {
    expect(fx.run(), isEmpty);
  });

  test('0: mermaid styling, unknown type, end node, two per section', () {
    fx.edit(
      'packages/yingyeothon_alpha/README.md',
      '  a --> b',
      '  a --> b\n  style a fill:#f00',
    );
    expect(fx.run(), [contains('mermaid styling is not allowed')]);
    fx.edit('packages/yingyeothon_alpha/README.md', '  style a fill:#f00', '');
    fx.edit('packages/yingyeothon_alpha/README.md', 'flowchart LR', 'pie');
    expect(fx.run(), [contains('known type')]);
    fx.edit('packages/yingyeothon_alpha/README.md', 'pie', 'flowchart LR');
    fx.edit('packages/yingyeothon_alpha/README.md', '  a --> b', '  a --> end');
    expect(fx.run(), [contains('named `end`')]);
    fx.edit('packages/yingyeothon_alpha/README.md', '  a --> end', '  a --> b');
    fx.edit(
      'docs/errors.md',
      'Close codes',
      '```mermaid\ngraph LR\n  x --> y\n```\n\n```mermaid\ngraph LR\n  p --> q\n```\n\nClose codes',
    );
    expect(fx.run(), [contains('2 mermaid blocks in one H2 section')]);
  });

  test('0: more than 12 flowchart nodes unless exhaustive', () {
    final nodes = List.generate(13, (i) => '  n$i --> n${i + 1}').join('\n');
    fx.edit('packages/yingyeothon_alpha/README.md', '  a --> b', nodes);
    expect(fx.run(), [contains('nodes; keep it to 12')]);
    fx.edit(
      'packages/yingyeothon_alpha/README.md',
      '# yingyeothon_alpha',
      '# yingyeothon_alpha\n<!-- check-docs: exhaustive -->',
    );
    expect(fx.run(), isEmpty);
  });

  test('0: no diagram on the troubleshooting page', () {
    fx.edit(
      'docs/troubleshooting.md',
      'Do this.',
      'Do this.\n\n```mermaid\ngraph LR\n  a --> b\n```',
    );
    expect(fx.run(), [contains('no diagrams on the troubleshooting page')]);
  });

  test('1: a dead link and a dead anchor', () {
    fx.edit('docs/README.md', '(errors.md)', '(nope.md)');
    expect(
      fx.run(),
      containsAll([contains('link target does not exist: nope.md')]),
    );
    fx.edit('docs/README.md', '(nope.md)', '(errors.md)');
    fx.edit('docs/README.md', '#a-symptom', '#missing');
    expect(fx.run(), [contains('anchor not found')]);
  });

  test('1: links inside code spans are ignored', () {
    fx.edit('docs/errors.md', 'Close codes', 'See `[x](nope.md)`. Close codes');
    expect(fx.run(), isEmpty);
  });

  test('2: an orphan docs page', () {
    fx.write('docs/lost.md', '# Lost\n');
    expect(fx.run(), [contains('docs/lost.md: not reachable')]);
  });

  test('3: package README structure', () {
    fx.edit(
      'packages/yingyeothon_alpha/README.md',
      '# yingyeothon_alpha',
      '# alpha',
    );
    expect(fx.run(), [contains('first heading must be `# yingyeothon_alpha`')]);
    fx.edit(
      'packages/yingyeothon_alpha/README.md',
      '# alpha',
      '# yingyeothon_alpha',
    );
    fx.edit(
      'packages/yingyeothon_alpha/README.md',
      '## Install\n\nAdd `yingyeothon_alpha`.',
      '## Install\n\nAdd it.',
    );
    expect(fx.run(), [
      contains('`## Install` does not name yingyeothon_alpha'),
    ]);
    fx.edit(
      'packages/yingyeothon_alpha/README.md',
      'Add it.',
      'Add `yingyeothon_alpha`.',
    );
    fx.edit(
      'packages/yingyeothon_alpha/README.md',
      '```mermaid\nflowchart LR\n  a --> b\n```\n',
      '',
    );
    expect(fx.run(), [
      contains('exactly one mermaid diagram above `## Install`, found 0'),
    ]);
  });

  test('3: root README table row', () {
    fx.edit(
      'README.md',
      '| [yingyeothon_beta](packages/yingyeothon_beta) | b |\n',
      '',
    );
    expect(fx.run(), [contains('no table row linking [yingyeothon_beta]')]);
  });

  test('4: dependency graph drift both ways', () {
    fx.edit(
      'README.md',
      '  yingyeothon_beta --> yingyeothon_alpha',
      '  yingyeothon_alpha --> yingyeothon_beta',
    );
    expect(
      fx.run(),
      containsAll([
        contains('missing the edge `yingyeothon_beta --> yingyeothon_alpha`'),
        contains('draws `yingyeothon_alpha --> yingyeothon_beta`'),
      ]),
    );
  });

  test('5: an export without show, a shown name not in Public API', () {
    fx.write(
      'packages/yingyeothon_beta/lib/yingyeothon_beta.dart',
      "export 'src/b.dart';\n",
    );
    expect(fx.run(), [contains('every export needs a `show` list')]);
    fx.write(
      'packages/yingyeothon_beta/lib/yingyeothon_beta.dart',
      "export 'src/b.dart' show Beta, Gamma;\n",
    );
    expect(fx.run(), [contains('does not mention `Gamma`')]);
  });

  test('6: an undocumented close code', () {
    fx.write(
      'packages/yingyeothon_gamebase_client/pubspec.yaml',
      'name: yingyeothon_gamebase_client\nversion: 0.1.0\n',
    );
    fx.write(
      'packages/yingyeothon_gamebase_client/lib/yingyeothon_gamebase_client.dart',
      "export 'src/x.dart' show X;\n",
    );
    fx.write(
      'packages/yingyeothon_gamebase_client/README.md',
      '# yingyeothon_gamebase_client\n\n```mermaid\ngraph LR\n  a --> b\n```\n\n## Install\n\n`yingyeothon_gamebase_client`\n\n## Public API\n\n`X`\n',
    );
    fx.edit(
      'README.md',
      '| [yingyeothon_beta]',
      '| [yingyeothon_gamebase_client](packages/yingyeothon_gamebase_client) | c |\n| [yingyeothon_beta]',
    );
    fx.write(
      'packages/yingyeothon_gamebase_client/lib/src/protocol/close_codes.dart',
      'static const int replaced = 4000;\nstatic const int idle = 4002;\nstatic const int local = 4900;\n',
    );
    expect(fx.run(), [contains('close code `4002` is not documented')]);
  });

  test('7: Korean outside a code span', () {
    fx.edit('docs/errors.md', 'Close codes', '한글 Close codes');
    expect(fx.run(), [contains('Korean outside a code span')]);
    fx.edit('docs/errors.md', '한글 Close codes', '`한글` Close codes');
    expect(fx.run(), isEmpty);
  });

  test('8: manifests', () {
    fx.write(
      'examples/demo/pubspec.yaml',
      'name: yingyeothon_demo\nresolution: workspace\n',
    );
    expect(
      fx.run(),
      containsAll([
        contains('examples are `publish_to: none`'),
        contains('not a yingyeothon_ package'),
        contains('stay outside the workspace'),
      ]),
    );
    fx.write(
      'examples/demo/pubspec.yaml',
      'name: demo_app\npublish_to: none\n',
    );
    fx.write('examples/README.md', 'nothing\n');
    expect(fx.run(), [contains('does not link examples/demo')]);
    fx.write('examples/README.md', '- [demo](demo/)\n');
    fx.write('tool/pubspec.yaml', 'name: t\nresolution: workspace\n');
    expect(fx.run(), [
      contains('outside packages/ must be `publish_to: none`'),
    ]);
  });

  test('9: version drift', () {
    fx.edit(
      'packages/yingyeothon_beta/pubspec.yaml',
      'version: 0.1.0',
      'version: 0.2.0',
    );
    expect(fx.run(), [contains('packages disagree on version')]);
  });

  group('lcov', () {
    test('sums DA and BRDA for included records only', () {
      const text = '''
SF:lib/a.dart
DA:1,1
DA:2,0
DA:2,3
BRDA:1,0,0,1
BRDA:1,0,1,-
BRDA:1,0,1,0
LF:99
LH:0
end_of_record
SF:other/b.dart
DA:1,0
end_of_record
''';
      final t = sumLcov(text, include: (p) => p.startsWith('lib/'));
      expect(t.linesFound, 2);
      expect(t.linesHit, 2);
      expect(t.branchesFound, 2);
      expect(t.branchesHit, 1);
      expect(t.linePercent, 100);
      expect(t.branchPercent, 50);
      final none = sumLcov(
        'SF:lib/x.dart\nend_of_record\n',
        include: (_) => true,
      );
      expect(none.linePercent, 100);
      expect(none.branchPercent, isNull);
    });
  });
}
