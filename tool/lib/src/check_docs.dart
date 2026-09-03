/// The documentation gate. See `tool/bin/check_docs.dart` for the list.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

/// Runs every check against the repository at [root]. Returns failures, one
/// line each, empty when green.
List<String> checkDocs(Directory root) {
  final failures = <String>[];
  final repo = _Repo(root);

  failures.addAll(_checkMermaid(repo));
  failures.addAll(_checkLinks(repo));
  failures.addAll(_checkOrphans(repo));
  failures.addAll(_checkPackageReadmes(repo));
  failures.addAll(_checkDependencyGraph(repo));
  failures.addAll(_checkPublicApi(repo));
  failures.addAll(_checkCloseCodes(repo));
  failures.addAll(_checkEnglishOnly(repo));
  failures.addAll(_checkManifests(repo));
  failures.addAll(_checkVersions(repo));
  return failures;
}

final class _Repo {
  _Repo(this.root);
  final Directory root;

  late final List<File> markdown =
      _collect(root).where((f) => f.path.endsWith('.md')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  late final List<Directory> packages = () {
    final dir = Directory('${root.path}/packages');
    if (!dir.existsSync()) return <Directory>[];
    return dir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }();

  String rel(FileSystemEntity e) =>
      e.path.substring(root.path.length + 1).replaceAll('\\', '/');

  static Iterable<File> _collect(Directory dir) sync* {
    for (final entity in dir.listSync()) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('.') || name == 'build' || name == 'coverage') {
        continue;
      }
      if (entity is Directory) {
        yield* _collect(entity);
      } else if (entity is File) {
        yield entity;
      }
    }
  }
}

// ---- markdown helpers ---------------------------------------------------

final class _Fence {
  _Fence(this.info, this.body, this.line);
  final String info;
  final List<String> body;
  final int line;
}

/// Splits a document into prose lines (fences blanked) and the fences.
({List<String> prose, List<_Fence> fences}) _split(String text) {
  final prose = <String>[];
  final fences = <_Fence>[];
  _Fence? open;
  var lineNo = 0;
  for (final line in text.split('\n')) {
    lineNo++;
    if (open == null) {
      if (line.trimLeft().startsWith('```')) {
        open = _Fence(line.trim().substring(3).trim(), <String>[], lineNo);
        prose.add('');
      } else {
        prose.add(line);
      }
    } else {
      if (line.trimLeft().startsWith('```')) {
        fences.add(open);
        open = null;
      } else {
        open.body.add(line);
      }
      prose.add('');
    }
  }
  return (prose: prose, fences: fences);
}

/// GitHub heading slug.
String _slug(String heading) {
  final stripped = heading
      .replaceAll(RegExp(r'`'), '')
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N} \-_]', unicode: true), '')
      .trim()
      .replaceAll(' ', '-');
  return stripped;
}

List<String> _headings(List<String> prose) => prose
    .where((l) => RegExp(r'^#{1,6} ').hasMatch(l))
    .map((l) => l.replaceFirst(RegExp(r'^#{1,6} '), '').trim())
    .toList();

// ---- 0. mermaid ---------------------------------------------------------

const _mermaidTypes = <String>[
  'graph',
  'flowchart',
  'sequenceDiagram',
  'stateDiagram-v2',
  'stateDiagram',
  'classDiagram',
];

List<String> _checkMermaid(_Repo repo) {
  final failures = <String>[];
  for (final file in repo.markdown) {
    final text = file.readAsStringSync();
    final doc = _split(text);
    final exhaustive = text.contains('<!-- check-docs: exhaustive -->');
    // One diagram per H2 section.
    final perSection = <int, int>{};
    final sectionStarts = <int>[0];
    for (var i = 0; i < doc.prose.length; i++) {
      if (doc.prose[i].startsWith('## ')) sectionStarts.add(i + 1);
    }
    for (final fence in doc.fences) {
      if (fence.info != 'mermaid') continue;
      final where = '${repo.rel(file)}:${fence.line}';
      final body = fence.body.where((l) => l.trim().isNotEmpty).toList();
      if (body.isEmpty) {
        failures.add('$where: empty mermaid block');
        continue;
      }
      final first = body.first.trim();
      if (!_mermaidTypes.any((t) => first == t || first.startsWith('$t '))) {
        failures.add(
          '$where: mermaid block does not start with a known type ($first)',
        );
      }
      for (final line in body) {
        final t = line.trim();
        if (RegExp(r'^(style|classDef|class|linkStyle)\b').hasMatch(t) ||
            t.contains('fill:')) {
          failures.add(
            '$where: mermaid styling is not allowed (${t.split(' ').first})',
          );
          break;
        }
      }
      if (RegExp(r'(^|[\s\[\(>-])end([\s\[\(\)\]]|$)')
          .hasMatch(body.skip(1).join('\n'))) {
        failures.add('$where: a mermaid node named `end` breaks the parser');
      }
      final section = sectionStarts.lastWhere(
        (s) => s <= fence.line - 1,
        orElse: () => 0,
      );
      perSection[section] = (perSection[section] ?? 0) + 1;
      if (!exhaustive && first.startsWith(RegExp('graph|flowchart'))) {
        final ids = <String>{};
        for (final line in body.skip(1)) {
          for (final m in RegExp(
            r'(?<![\w"])([A-Za-z_][\w]*)\s*(\[|\(|\{|-->|---|-\.|==>|$)',
          ).allMatches(line.trim())) {
            final id = m.group(1)!;
            if (id != 'subgraph' && id != 'direction') ids.add(id);
          }
        }
        if (ids.length > 12) {
          failures.add(
            '$where: flowchart has ${ids.length} nodes; keep it to 12 or mark the file exhaustive',
          );
        }
      }
    }
    for (final entry in perSection.entries) {
      if (entry.value > 1) {
        failures.add(
          '${repo.rel(file)}: ${entry.value} mermaid blocks in one H2 section (line ${entry.key + 1}); one per section',
        );
      }
    }
    if (repo.rel(file) == 'docs/troubleshooting.md' &&
        doc.fences.any((f) => f.info == 'mermaid')) {
      failures.add(
        'docs/troubleshooting.md: no diagrams on the troubleshooting page',
      );
    }
  }
  return failures;
}

// ---- 1. links ----------------------------------------------------------

final _linkPattern = RegExp(r'(?<!!)\[[^\]]*\]\(([^)\s]+)\)');
final _refPattern = RegExp(r'^\[([^\]]+)\]:\s*(\S+)', multiLine: true);

List<String> _checkLinks(_Repo repo) {
  final failures = <String>[];
  final headingsOf = <String, Set<String>>{};
  for (final file in repo.markdown) {
    headingsOf[file.absolute.path] = _headings(
      _split(file.readAsStringSync()).prose,
    ).map(_slug).toSet();
  }
  for (final file in repo.markdown) {
    final text = file.readAsStringSync();
    final prose = _split(text).prose
        .join('\n')
        .replaceAll(RegExp(r'`[^`\n]*`'), '');
    final targets = <String>[
      ..._linkPattern.allMatches(prose).map((m) => m.group(1)!),
      ..._refPattern.allMatches(prose).map((m) => m.group(2)!),
    ];
    for (final target in targets) {
      if (target.startsWith('http://') ||
          target.startsWith('https://') ||
          target.startsWith('mailto:')) {
        continue;
      }
      final hashAt = target.indexOf('#');
      final path = hashAt < 0 ? target : target.substring(0, hashAt);
      final anchor = hashAt < 0 ? null : target.substring(hashAt + 1);
      final resolved = path.isEmpty
          ? file
          : File(Uri.file('${file.parent.path}/').resolve(path).toFilePath());
      final exists =
          resolved.existsSync() || Directory(resolved.path).existsSync();
      if (!exists) {
        failures.add('${repo.rel(file)}: link target does not exist: $target');
        continue;
      }
      if (anchor != null && resolved.path.endsWith('.md')) {
        final known = headingsOf[resolved.absolute.path] ?? <String>{};
        if (!known.contains(anchor)) {
          failures.add('${repo.rel(file)}: anchor not found: $target');
        }
      }
    }
  }
  return failures;
}

// ---- 2. orphans ---------------------------------------------------------

List<String> _checkOrphans(_Repo repo) {
  final docs = Directory('${repo.root.path}/docs');
  if (!docs.existsSync()) return const <String>[];
  final index = File('${docs.path}/README.md');
  if (!index.existsSync()) return <String>['docs/README.md is missing'];
  final reachable = <String>{index.absolute.path};
  final queue = <File>[index];
  while (queue.isNotEmpty) {
    final file = queue.removeLast();
    final prose = _split(file.readAsStringSync()).prose.join('\n');
    for (final m in _linkPattern.allMatches(prose)) {
      final target = m.group(1)!.split('#').first;
      if (target.isEmpty || target.contains('://')) continue;
      final resolved = File(
        Uri.file('${file.parent.path}/').resolve(target).toFilePath(),
      );
      if (resolved.existsSync() && reachable.add(resolved.absolute.path)) {
        queue.add(resolved);
      }
    }
  }
  final failures = <String>[];
  for (final file in repo.markdown) {
    if (!file.absolute.path.startsWith(docs.absolute.path)) continue;
    if (!reachable.contains(file.absolute.path)) {
      failures.add('${repo.rel(file)}: not reachable from docs/README.md');
    }
  }
  return failures;
}

// ---- 3. package READMEs -------------------------------------------------

String _packageName(Directory package) {
  final pubspec = File('${package.path}/pubspec.yaml');
  final yaml = loadYaml(pubspec.readAsStringSync()) as YamlMap;
  return yaml['name'] as String;
}

List<String> _checkPackageReadmes(_Repo repo) {
  final failures = <String>[];
  final rootReadme = File('${repo.root.path}/README.md');
  final rootText = rootReadme.existsSync() ? rootReadme.readAsStringSync() : '';
  for (final package in repo.packages) {
    final name = _packageName(package);
    final readme = File('${package.path}/README.md');
    final where = '${repo.rel(package)}/README.md';
    if (!readme.existsSync()) {
      failures.add('$where: missing');
      continue;
    }
    final text = readme.readAsStringSync();
    final doc = _split(text);
    final h1 = doc.prose.firstWhere(
      (l) => l.startsWith('# '),
      orElse: () => '',
    );
    if (h1 != '# $name') {
      failures.add('$where: first heading must be `# $name`');
    }
    final installAt = doc.prose.indexWhere((l) => l == '## Install');
    if (installAt < 0) {
      failures.add('$where: missing `## Install`');
    } else {
      final above = doc.fences
          .where((f) => f.info == 'mermaid' && f.line <= installAt)
          .length;
      if (above != 1) {
        failures.add(
          '$where: expected exactly one mermaid diagram above `## Install`, found $above',
        );
      }
      final installEnd = doc.prose.indexWhere(
        (l) => l.startsWith('## '),
        installAt + 1,
      );
      final installSection = text
          .split('\n')
          .sublist(installAt, installEnd < 0 ? doc.prose.length : installEnd)
          .join('\n');
      if (!installSection.contains(name)) {
        failures.add('$where: `## Install` does not name $name');
      }
    }
    if (!doc.prose.contains('## Public API')) {
      failures.add('$where: missing `## Public API`');
    }
    if (!rootText.contains('[$name](packages/$name)')) {
      failures.add('README.md: no table row linking [$name](packages/$name)');
    }
  }
  return failures;
}

// ---- 4. dependency graph ------------------------------------------------

Set<String> _edgesFromPubspecs(_Repo repo) {
  final edges = <String>{};
  for (final package in repo.packages) {
    final yaml = loadYaml(
      File('${package.path}/pubspec.yaml').readAsStringSync(),
    ) as YamlMap;
    final name = yaml['name'] as String;
    final deps = yaml['dependencies'];
    if (deps is YamlMap) {
      for (final dep in deps.keys) {
        if ((dep as String).startsWith('yingyeothon_')) {
          edges.add('$name --> $dep');
        }
      }
    }
  }
  return edges;
}

List<String> _checkDependencyGraph(_Repo repo) {
  final readme = File('${repo.root.path}/README.md');
  if (!readme.existsSync()) return <String>['README.md is missing'];
  final fences = _split(readme.readAsStringSync()).fences
      .where((f) => f.info == 'mermaid');
  final graph = fences
      .where((f) => f.body.first.trim().startsWith(RegExp('graph|flowchart')))
      .firstOrNull;
  if (graph == null) return <String>['README.md: no mermaid dependency graph'];
  final drawn = <String>{};
  for (final line in graph.body.skip(1)) {
    final m = RegExp(r'^\s*(\w+)\s*-->\s*(\w+)\s*$').firstMatch(line);
    if (m != null) drawn.add('${m.group(1)} --> ${m.group(2)}');
  }
  final actual = _edgesFromPubspecs(repo);
  final failures = <String>[];
  for (final e in actual.difference(drawn)) {
    failures.add('README.md: dependency graph is missing the edge `$e`');
  }
  for (final e in drawn.difference(actual)) {
    failures.add(
      'README.md: dependency graph draws `$e`, which no pubspec declares',
    );
  }
  return failures;
}

// ---- 5. public API ------------------------------------------------------

List<String> _checkPublicApi(_Repo repo) {
  final failures = <String>[];
  for (final package in repo.packages) {
    final name = _packageName(package);
    final barrel = File('${package.path}/lib/$name.dart');
    final where = '${repo.rel(package)}/lib/$name.dart';
    if (!barrel.existsSync()) {
      failures.add('$where: missing barrel');
      continue;
    }
    final text = barrel.readAsStringSync().replaceAll(RegExp(r'///[^\n]*'), '');
    final shown = <String>{};
    for (final m in RegExp(r'export\s+([^;]+);').allMatches(text)) {
      final clause = m.group(1)!;
      final show = RegExp(r'\bshow\s+([^;]+)$').firstMatch(clause.trim());
      if (show == null) {
        failures.add('$where: every export needs a `show` list ($clause)');
        continue;
      }
      for (final id in show.group(1)!.split(',')) {
        final trimmed = id.trim();
        if (trimmed.isNotEmpty) shown.add(trimmed);
      }
    }
    final readme = File('${package.path}/README.md');
    if (!readme.existsSync()) continue;
    final readmeText = readme.readAsStringSync();
    final apiAt = readmeText.indexOf('## Public API');
    if (apiAt < 0) continue;
    final nextH2 = readmeText.indexOf('\n## ', apiAt + 1);
    final section = readmeText.substring(
      apiAt,
      nextH2 < 0 ? readmeText.length : nextH2,
    );
    for (final id in shown) {
      if (!RegExp('\\b${RegExp.escape(id)}\\b').hasMatch(section)) {
        failures.add(
          '${repo.rel(package)}/README.md: `## Public API` does not mention `$id`',
        );
      }
    }
  }
  return failures;
}

// ---- 6. close codes -----------------------------------------------------

List<String> _checkCloseCodes(_Repo repo) {
  final source = File(
    '${repo.root.path}/packages/yingyeothon_gamebase_client/lib/src/protocol/close_codes.dart',
  );
  final errors = File('${repo.root.path}/docs/errors.md');
  if (!source.existsSync() || !errors.existsSync()) return const <String>[];
  final codes = RegExp(r'static const int \w+ = (\d{4});')
      .allMatches(source.readAsStringSync())
      .map((m) => m.group(1)!)
      .where((c) => c.startsWith('40'));
  final text = errors.readAsStringSync();
  return <String>[
    for (final code in codes)
      if (!text.contains('`$code`'))
        'docs/errors.md: close code `$code` is not documented',
  ];
}

// ---- 7. English only ----------------------------------------------------

List<String> _checkEnglishOnly(_Repo repo) {
  final hangul = RegExp(r'[ㄱ-ㆎ가-힣]');
  final failures = <String>[];
  for (final file in repo.markdown) {
    final prose = _split(file.readAsStringSync()).prose;
    for (var i = 0; i < prose.length; i++) {
      final line = prose[i].replaceAll(RegExp(r'`[^`]*`'), '');
      if (hangul.hasMatch(line)) {
        failures.add(
          '${repo.rel(file)}:${i + 1}: repository content is English; Korean outside a code span',
        );
      }
    }
  }
  return failures;
}

// ---- 8. manifests -------------------------------------------------------

List<String> _checkManifests(_Repo repo) {
  final failures = <String>[];
  final rootPubspec = File('${repo.root.path}/pubspec.yaml');
  if (rootPubspec.existsSync()) {
    final yaml = loadYaml(rootPubspec.readAsStringSync()) as YamlMap;
    final members =
        (yaml['workspace'] as YamlList?)?.cast<String>() ?? const <String>[];
    for (final member in members) {
      if (member.startsWith('packages/')) continue;
      final pubspec = File('${repo.root.path}/$member/pubspec.yaml');
      if (!pubspec.existsSync()) {
        failures.add('pubspec.yaml: workspace member $member has no pubspec');
        continue;
      }
      final m = loadYaml(pubspec.readAsStringSync()) as YamlMap;
      if (m['publish_to'] != 'none') {
        failures.add(
          '$member/pubspec.yaml: a workspace member outside packages/ must be `publish_to: none`',
        );
      }
    }
  }
  final examples = Directory('${repo.root.path}/examples');
  if (!examples.existsSync()) return failures;
  final index = File('${examples.path}/README.md');
  final indexText = index.existsSync() ? index.readAsStringSync() : '';
  if (!index.existsSync()) {
    failures.add('examples/README.md is missing');
  }
  for (final dir in examples.listSync().whereType<Directory>()) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final m = loadYaml(pubspec.readAsStringSync()) as YamlMap;
    if (m['publish_to'] != 'none') {
      failures.add(
        'examples/$name/pubspec.yaml: examples are `publish_to: none`',
      );
    }
    if ((m['name'] as String).startsWith('yingyeothon_')) {
      failures.add(
        'examples/$name/pubspec.yaml: an example is not a yingyeothon_ package',
      );
    }
    if (m['resolution'] == 'workspace') {
      failures.add(
        'examples/$name/pubspec.yaml: examples stay outside the workspace (rules/tooling.md)',
      );
    }
    if (!indexText.contains('($name/')) {
      failures.add('examples/README.md: does not link examples/$name');
    }
  }
  return failures;
}

// ---- 9. versions --------------------------------------------------------

List<String> _checkVersions(_Repo repo) {
  final versions = <String, String>{};
  for (final package in repo.packages) {
    final yaml = loadYaml(
      File('${package.path}/pubspec.yaml').readAsStringSync(),
    ) as YamlMap;
    versions[yaml['name'] as String] = yaml['version'] as String? ?? '';
  }
  final distinct = versions.values.toSet();
  if (distinct.length <= 1) return const <String>[];
  return <String>[
    'packages disagree on version: ${versions.entries.map((e) => '${e.key}=${e.value}').join(', ')} (rules/release.md: one version)',
  ];
}
