import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// The period names a board may keep. An open string set, not an enum, so a
/// period the console adds later cannot become a parse failure.
abstract final class LbPeriod {
  /// One bucket for ever; its key is the empty string.
  static const String alltime = 'alltime';

  /// One bucket per day in `Asia/Seoul`; key `YYYY-MM-DD`.
  static const String daily = 'daily';

  /// One bucket per ISO week in `Asia/Seoul`; key `YYYY-Www`.
  static const String weekly = 'weekly';
}

/// Who may write a board's scores.
abstract final class LbSubmit {
  /// The doc apiKey alone.
  static const String server = 'server';

  /// Also a player, for its own row; the apiKey on anyone's behalf.
  static const String owner = 'owner';
}

/// How a new score meets the stored one.
abstract final class LbRule {
  /// The better one stays.
  static const String best = 'best';

  /// The new one replaces it.
  static const String latest = 'latest';

  /// They add up, saturating at the safe-integer bound.
  static const String sum = 'sum';
}

/// Which end ranks first.
abstract final class LbOrder {
  /// Larger is better.
  static const String desc = 'desc';

  /// Smaller is better (a time).
  static const String asc = 'asc';
}

/// A live bucket: the period, the key the platform computed from its own
/// clock, and the second it rolls over. A client never names a key.
final class LbBucket {
  /// Creates a bucket.
  const LbBucket({
    required this.period,
    required this.periodKey,
    this.periodEndsAt,
  });

  /// Reads the three fields; a missing string reads as empty, a missing or
  /// `null` end as `null`.
  factory LbBucket.fromJson(JsonObject json) => LbBucket(
    period: json.getString('period') ?? '',
    periodKey: json.getString('periodKey') ?? '',
    periodEndsAt: json.getInt('periodEndsAt'),
  );

  /// An [LbPeriod] value.
  final String period;

  /// The bucket key: `''` for alltime, `YYYY-MM-DD`, `YYYY-Www`.
  final String periodKey;

  /// Epoch second the bucket ends; `null` for alltime, which never does.
  final int? periodEndsAt;
}

/// The board's shape from `GET /lb/{board}`.
final class LeaderboardInfo {
  /// Creates an info.
  const LeaderboardInfo({
    required this.id,
    required this.name,
    required this.submit,
    required this.rule,
    required this.order,
    required this.maxEntries,
    required this.periods,
    required this.raw,
  });

  /// Reads the object. A missing string reads as empty, a missing number as
  /// `0`, a missing list as empty.
  factory LeaderboardInfo.fromJson(JsonObject json) => LeaderboardInfo(
    id: json.getString('id') ?? '',
    name: json.getString('name') ?? '',
    submit: json.getString('submit') ?? '',
    rule: json.getString('rule') ?? '',
    order: json.getString('order') ?? '',
    maxEntries: json.getInt('maxEntries') ?? 0,
    periods: _buckets(json.getListOrEmpty('periods')),
    raw: json,
  );

  /// The `lb_` id.
  final String id;

  /// The console name.
  final String name;

  /// An [LbSubmit] value.
  final String submit;

  /// An [LbRule] value.
  final String rule;

  /// An [LbOrder] value.
  final String order;

  /// Rows one bucket may hold.
  final int maxEntries;

  /// The live bucket of every period the board keeps, in the server's
  /// order; the first is the default period of `top` and `score`.
  final List<LbBucket> periods;

  /// The object as received.
  final JsonObject raw;
}

/// One row of a ranked page.
final class LbEntry {
  /// Creates a row.
  const LbEntry({
    required this.rank,
    required this.owner,
    required this.score,
    required this.updatedAt,
    this.meta,
    required this.raw,
  });

  /// `1 + count(better)`: equal scores share a rank.
  final int rank;

  /// The owner's id.
  final String owner;

  /// The stored score.
  final int score;

  /// The stored `meta` text, byte for byte, or `null`.
  final String? meta;

  /// Epoch second of the last accepted submission.
  final int updatedAt;

  /// The row as received.
  final JsonObject raw;
}

/// A page of `GET /lb/{board}/top`.
final class LbPage {
  /// Creates a page.
  const LbPage({
    required this.bucket,
    required this.total,
    required this.entries,
  });

  /// Which bucket answered.
  final LbBucket bucket;

  /// Rows in the bucket.
  final int total;

  /// The page, ranked.
  final List<LbEntry> entries;
}

/// One owner's row with its rank, from `GET /lb/{board}/scores/{owner}`.
final class LbScore {
  /// Creates a score.
  const LbScore({
    required this.bucket,
    required this.owner,
    required this.score,
    required this.rank,
    required this.total,
    required this.updatedAt,
    this.meta,
    required this.raw,
  });

  /// Which bucket answered.
  final LbBucket bucket;

  /// The owner's id, as the server resolved it (`me` becomes the id).
  final String owner;

  /// The stored score.
  final int score;

  /// `1 + count(better)`.
  final int rank;

  /// Rows in the bucket.
  final int total;

  /// Epoch second of the last accepted submission.
  final int updatedAt;

  /// The stored `meta` text, or `null`.
  final String? meta;

  /// The object as received.
  final JsonObject raw;
}

/// What one bucket holds after a submission.
final class LbStoredScore {
  /// Creates a stored score.
  const LbStoredScore({
    required this.bucket,
    required this.score,
    required this.updatedAt,
  });

  /// The bucket.
  final LbBucket bucket;

  /// What is stored there now: on a `best` board, whether you improved.
  final int score;

  /// Epoch second of the row's last accepted submission.
  final int updatedAt;
}

/// What `submit` learned: the score sent and what every bucket holds now.
/// No rank: that would be one count per bucket on the hot path.
final class LbSubmitResult {
  /// Creates a result.
  const LbSubmitResult({required this.submitted, required this.periods});

  /// The score as sent.
  final int submitted;

  /// One per bucket the board keeps.
  final List<LbStoredScore> periods;
}

/// What `clearPeriod` did: one batch of the current bucket.
final class LbClearResult {
  /// Creates a result.
  const LbClearResult({
    required this.bucket,
    required this.deleted,
    required this.truncated,
  });

  /// The bucket.
  final LbBucket bucket;

  /// Rows this call removed.
  final int deleted;

  /// Whether a batch's worth remained: call again.
  final bool truncated;
}

List<LbBucket> _buckets(JsonList list) => <LbBucket>[
  for (final item in list)
    if (item is JsonObject) LbBucket.fromJson(item),
];
