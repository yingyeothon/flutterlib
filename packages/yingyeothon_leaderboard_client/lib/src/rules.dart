import 'dart:convert';

/// The server's rules the client refuses locally, and nothing more.
///
/// Every constant is a copy of one in the `service` repository
/// (`packages/console-db/src/leaderboard.ts`, with the owner grammar from
/// `kvstore.ts`); when that file changes, this one follows. A local refusal
/// is a fast `ArgumentError` whose message names the rule and never the
/// input; the server is the enforcement.
abstract final class LbRules {
  /// `LB_ID_RE`: an `lb_` id goes on the path as is.
  static final RegExp boardIdPattern = RegExp(r'^lb_[0-9a-z]{26}$');

  /// The console's board name grammar (`checkLbName` is kv's name grammar,
  /// so a name never folds onto an id).
  static final RegExp boardNamePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
  );

  /// `KV_OWNER_ID` plus the player alias `me`: a score's owner is a player
  /// id, or `{kind}:{id}` when a server names a guild.
  static final RegExp ownerPattern = RegExp(
    r'^(?:me|[0-9a-f]{32}|[a-z]{1,8}:[A-Za-z0-9_-]{1,48})$',
  );

  /// `LB_PERIODS`: the period names a board may keep, in the server's order.
  static const List<String> periods = <String>['alltime', 'daily', 'weekly'];

  /// `LB_TOP_LIMIT_MAX`; the minimum is 1 and the server default 20.
  static const int topLimitMax = 100;

  /// `LB_TOP_OFFSET_MAX`: past it a caller wants one owner's score.
  static const int topOffsetMax = 1000;

  /// `LB_META_BYTES`: the largest `meta`, in UTF-8 bytes as sent.
  static const int maxMetaBytes = 1024;

  /// `LB_SCORE_MAX` (`Number.MAX_SAFE_INTEGER`); the minimum is its negative.
  static const int scoreMax = 9007199254740991;

  /// The alias the server resolves to the token's own user id.
  static const String selfOwner = 'me';

  static final RegExp _control = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

  /// Returns [ref] when it is an `lb_` id or a name the console could have
  /// accepted; throws otherwise.
  static String checkBoardRef(String ref) {
    if (boardIdPattern.hasMatch(ref) || boardNamePattern.hasMatch(ref)) {
      return ref;
    }
    throw ArgumentError(
      'lb board must be an lb_ id or a name matching '
      '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\$',
    );
  }

  /// Returns [owner] when it is `me`, 32 hex characters or `{kind}:{id}`;
  /// throws otherwise.
  static String checkOwner(String owner) {
    if (ownerPattern.hasMatch(owner)) return owner;
    throw ArgumentError('lb owner must be me, 32 hex characters, or kind:id');
  }

  /// Returns [period] when it is `null` or one of [periods]; throws
  /// otherwise. Whether the board keeps it is the server's answer (`400`).
  static String? checkPeriod(String? period) {
    if (period == null || periods.contains(period)) return period;
    throw ArgumentError('lb period must be one of ${periods.join(', ')}');
  }

  /// Returns [limit] when it is `null` or 1 … [topLimitMax]; throws
  /// otherwise.
  static int? checkLimit(int? limit) {
    if (limit == null) return null;
    if (limit >= 1 && limit <= topLimitMax) return limit;
    throw ArgumentError('lb top limit must be between 1 and $topLimitMax');
  }

  /// Returns [offset] when it is `null` or 0 … [topOffsetMax]; throws
  /// otherwise.
  static int? checkOffset(int? offset) {
    if (offset == null) return null;
    if (offset >= 0 && offset <= topOffsetMax) return offset;
    throw ArgumentError('lb top offset must be between 0 and $topOffsetMax');
  }

  /// Returns [score] when it is a safe integer; throws otherwise.
  static int checkScore(int score) {
    if (score >= -scoreMax && score <= scoreMax) return score;
    throw ArgumentError('lb score must be a safe integer');
  }

  /// Returns [meta] when it is `null`, free of C0/C1 controls and within
  /// [maxMetaBytes]; throws otherwise. The message carries the cap, never
  /// the text or its length.
  static String? checkMeta(String? meta) {
    if (meta == null) return null;
    if (_control.hasMatch(meta)) {
      throw ArgumentError('lb meta must not contain control characters');
    }
    if (utf8.encode(meta).length > maxMetaBytes) {
      throw ArgumentError('lb meta exceeds $maxMetaBytes bytes');
    }
    return meta;
  }
}
