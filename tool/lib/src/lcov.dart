/// LCOV parsing for the coverage gate.
library;

/// Line and branch totals over a set of LCOV records.
final class CoverageTotals {
  CoverageTotals({
    required this.linesFound,
    required this.linesHit,
    required this.branchesFound,
    required this.branchesHit,
  });

  final int linesFound;
  final int linesHit;
  final int branchesFound;
  final int branchesHit;

  double get linePercent => linesFound == 0 ? 100 : linesHit * 100 / linesFound;

  /// `null` when the report carries no branch data.
  double? get branchPercent =>
      branchesFound == 0 ? null : branchesHit * 100 / branchesFound;
}

/// Sums the records whose `SF:` path satisfies [include].
///
/// Lines are counted from `DA:` entries (hit when the count is above zero)
/// rather than `LF:`/`LH:`, because a record may carry the same line more
/// than once; branches from `BRDA:` the same way.
CoverageTotals sumLcov(
  String text, {
  required bool Function(String path) include,
}) {
  var linesFound = 0;
  var linesHit = 0;
  var branchesFound = 0;
  var branchesHit = 0;
  var counting = false;
  final seenLines = <int, bool>{};
  final seenBranches = <String, bool>{};

  void flush() {
    for (final hit in seenLines.values) {
      linesFound++;
      if (hit) linesHit++;
    }
    for (final hit in seenBranches.values) {
      branchesFound++;
      if (hit) branchesHit++;
    }
    seenLines.clear();
    seenBranches.clear();
  }

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('SF:')) {
      flush();
      counting = include(line.substring(3));
    } else if (line == 'end_of_record') {
      flush();
      counting = false;
    } else if (!counting) {
      continue;
    } else if (line.startsWith('DA:')) {
      final parts = line.substring(3).split(',');
      final no = int.tryParse(parts[0]);
      final count = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
      if (no != null) seenLines[no] = (seenLines[no] ?? false) || count > 0;
    } else if (line.startsWith('BRDA:')) {
      final parts = line.substring(5).split(',');
      if (parts.length < 4) continue;
      final key = '${parts[0]}:${parts[1]}:${parts[2]}';
      final taken = parts[3];
      final hit = taken != '-' && (int.tryParse(taken) ?? 0) > 0;
      seenBranches[key] = (seenBranches[key] ?? false) || hit;
    }
  }
  flush();
  return CoverageTotals(
    linesFound: linesFound,
    linesHit: linesHit,
    branchesFound: branchesFound,
    branchesHit: branchesHit,
  );
}
