/// Which gateway channel a socket is on.
enum GatewayChannelKind {
  /// Positions, chat, parties.
  lobby,

  /// A dungeon run bridged to a game actor.
  q,
}

/// Close codes the gateway sends (4000–4005) and the one the SDK uses for a
/// close it initiates (4900; a client may only send 1000 or 3000–4999).
abstract final class GatewayCloseCode {
  /// A newer socket of the same user replaced this one. Do not reconnect.
  static const int replaced = 4000;

  /// `q` only: the actor stopped consuming; the run is aborted, not finished.
  static const int aborted = 4001;

  /// No pong within the idle window.
  static const int idle = 4002;

  /// Too many refused messages on one socket; a client bug.
  static const int policy = 4003;

  /// The channel expired or was disabled.
  static const int channelGone = 4004;

  /// The outbound queue filled with control frames; reconnect to resync.
  static const int tooSlow = 4005;

  /// An SDK-initiated close (hello timeout, wrong subprotocol, oversized
  /// frame). Never sent by the gateway.
  static const int local = 4900;
}

/// What the client should do after a close.
enum CloseDispositionKind {
  /// Retry with backoff.
  reconnect,

  /// Terminal; the session is over.
  stop,

  /// `q`: the actor died. Retry only with a new `gameId`.
  aborted,

  /// `q`: the game dropped you after a normal end.
  finished,

  /// The gateway says the client misbehaved; fix the client.
  clientBug,
}

/// A close code's meaning.
final class CloseDisposition {
  /// Creates a disposition.
  const CloseDisposition(this.kind, this.reason);

  /// What to do.
  final CloseDispositionKind kind;

  /// An SDK-authored explanation — never text the peer chose.
  final String reason;
}

/// Maps a close code to what the client should do. Every code the gateway
/// documents is listed; anything else is a transient network failure and is
/// retried with backoff.
CloseDisposition classifyClose(int code, GatewayChannelKind kind) {
  switch (code) {
    case GatewayCloseCode.replaced:
      return const CloseDisposition(
        CloseDispositionKind.stop,
        'replaced by a newer connection',
      );
    case GatewayCloseCode.aborted:
      return kind == GatewayChannelKind.q
          ? const CloseDisposition(
              CloseDispositionKind.aborted,
              'the game actor stopped responding',
            )
          : const CloseDisposition(CloseDispositionKind.stop, 'aborted');
    case GatewayCloseCode.idle:
      return const CloseDisposition(
        CloseDispositionKind.reconnect,
        'idle timeout',
      );
    case GatewayCloseCode.policy:
      return const CloseDisposition(
        CloseDispositionKind.clientBug,
        'too many refused messages',
      );
    case GatewayCloseCode.channelGone:
      return const CloseDisposition(
        CloseDispositionKind.stop,
        'channel expired or disabled',
      );
    case GatewayCloseCode.tooSlow:
      return const CloseDisposition(
        CloseDispositionKind.reconnect,
        'client too slow; resync',
      );
    case 1000:
      return kind == GatewayChannelKind.q
          ? const CloseDisposition(
              CloseDispositionKind.finished,
              'the game dropped the connection',
            )
          : const CloseDisposition(
              CloseDispositionKind.stop,
              'closed normally',
            );
    case 1001:
      return const CloseDisposition(
        CloseDispositionKind.reconnect,
        'gateway restarting',
      );
    case 1003:
      return const CloseDisposition(
        CloseDispositionKind.clientBug,
        'binary frame sent',
      );
    case 1009:
      return const CloseDisposition(
        CloseDispositionKind.clientBug,
        'frame too large',
      );
    case 1011:
      return const CloseDisposition(
        CloseDispositionKind.reconnect,
        'gateway failed to enter the game',
      );
    default:
      return CloseDisposition(
        CloseDispositionKind.reconnect,
        'connection lost ($code)',
      );
  }
}
