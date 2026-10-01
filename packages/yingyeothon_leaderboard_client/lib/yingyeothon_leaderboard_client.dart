/// A client for yyt leaderboards served by the state stack.
///
/// One [LeaderboardClient] per credential: the channel JWT of a player or
/// the auth channel's doc apiKey of the game's server. It addresses a board
/// by its console name or its `lb_` id, submits a score (one write to every
/// bucket the board keeps), reads a ranked page of a bucket and one owner's
/// own rank, and, for the server, deletes.
///
/// Nothing here ever logs, throws, or returns a message that contains the
/// token, an owner, a `meta` or a URL; a failure is a status and a code.
library;

export 'src/errors.dart' show LeaderboardException;
export 'src/leaderboard_client.dart'
    show Leaderboard, LeaderboardClient, LeaderboardClientOptions;
export 'src/rules.dart' show LbRules;
export 'src/types.dart'
    show
        LbBucket,
        LbClearResult,
        LbEntry,
        LbOrder,
        LbPage,
        LbPeriod,
        LbRule,
        LbScore,
        LbStoredScore,
        LbSubmit,
        LbSubmitResult,
        LeaderboardInfo;
