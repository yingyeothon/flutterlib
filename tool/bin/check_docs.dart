// The documentation gate. Every check is mechanical so a drift is caught by
// CI rather than by a reader:
//
//  0. mermaid blocks: known type, no styling, no `end` node, one per H2
//     section, at most 12 nodes in a flowchart (mark a file
//     `<!-- check-docs: exhaustive -->` to lift that), none on the
//     troubleshooting page;
//  1. every relative link and heading anchor resolves;
//  2. every docs/*.md page is reachable from docs/README.md;
//  3. every package README has `# <name>` first, exactly one mermaid diagram
//     above `## Install`, an `## Install` that names the package, a
//     `## Public API`, and a row in the root README table;
//  4. the root README's mermaid dependency graph equals the yingyeothon_*
//     edges the pubspecs declare;
//  5. every barrel export carries a `show` list and every shown name is
//     mentioned under `## Public API`;
//  6. every 40xx close code constant is documented in docs/errors.md;
//  7. no Korean outside code spans (repository content is English);
//  8. workspace members outside packages/ and every example are
//     `publish_to: none`; examples are not yingyeothon_ packages, stay out of
//     the workspace, and are linked from examples/README.md;
//  9. every package carries the same version.
//
// The mermaid check is a heuristic, not a parser; it catches what has bitten
// the sibling repositories, not every syntax error.
import 'dart:io';

import 'package:yyt_tool/src/check_docs.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? Directory(args.first) : _repoRoot();
  final failures = checkDocs(root);
  for (final f in failures) {
    print('FAIL: $f');
  }
  if (failures.isNotEmpty) {
    print('check_docs: ${failures.length} problem(s)');
    exit(1);
  }
  print('check_docs: ok');
}

Directory _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync() ||
      !Directory('${dir.path}/packages').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln('check_docs: run from inside the repository');
      exit(2);
    }
    dir = parent;
  }
  return dir;
}
