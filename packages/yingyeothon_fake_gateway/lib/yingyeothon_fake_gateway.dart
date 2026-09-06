/// An in-process stand-in for the yyt realtime gateway.
///
/// It speaks the lobby and `q` wire protocols closely enough for the SDK's
/// integration tests and for the example app's offline demo: the bearer
/// subprotocol handshake, `hello`, zones and the peer map frames, chat and
/// events by scope, parties with the gateway's `omitempty` marshalling,
/// `ping`/`pong`, the documented refusal codes, and the close codes a test
/// injects, plus the state stack's `/kv/*` routes over an in-memory store
/// for the key-value client. It is not the gateway: no rate limiting, no area of interest,
/// no persistence, no real token verification — a token is accepted as an
/// identity, and its user id is the JWT `sub` when it parses as one or the
/// token text itself otherwise.
///
/// Never publish this package; it is `publish_to: none`.
library;

export 'src/fake_gateway.dart'
    show FakeGateway, FakeGatewayOptions, GameFrameHandler, GameSession;
export 'src/fake_kv.dart' show FakeKvCollection, FakeKvStore;
