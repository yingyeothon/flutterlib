# Troubleshooting

Symptom → one check → where to read.

## `connect()` throws `GatewayStoppedException` almost at once

The token or the channel. Run `AuthClient.verify(jwt)`: `null` means the token is
bad or expired — sign in again; a `ChannelToken` means the token is fine and the
channel id or URL is wrong. [Authentication](authentication.md#checking-a-token-by-hand),
[Console and options](console-and-options.md).

## It retries four times, then stops on the fifth failed handshake

Every attempt closed before it opened — a refused handshake. Same check as above;
on `q`, also confirm you are in the game's start event (`403`).
[Connection lifecycle](connection-lifecycle.md#reconnect-policy).

## `stopped` with reason "gateway did not select the bearer subprotocol"

The URL is not the gateway (a proxy, a wrong port, an `http` health endpoint).
`GatewayClientOptions.url` is the origin from the channel's `wsUrl`, nothing more.

## Connected, but no peers ever appear

Unless the gateway retained a position for you, you have no zone until your first
`pos`. Send one with `hello.zone`, watch `snapshots`. [Lobby](lobby.md#positions-and-zones).

## `pos()` throws `GatewayClientException(capability_off)`

`hello.capabilities.pos` is `false` on this channel; the console setting decides.
[Console and options](console-and-options.md#what-the-console-setting-becomes-in-hello).

## `refused` with `move_too_far`

A jump over the channel's `maxMoveDelta` inside one zone. Move in steps, or change
zone. [Errors](errors.md#refusals). Right after connecting, it is
[a restored position](#every-move-is-refused-with-move_too_far-right-after-connecting).

## `refused` with `too_long`, then the socket closes with `4003`

Fifty refusals on one socket end it. Keep `text` at 1–1024 bytes and `payload`
under 8 KB (an empty or over-64-byte event `name` is `bad_message`); the SDK does not
check these for you. [Errors](errors.md#what-the-sdk-does-not-check).

## The socket closes with `4000` when a second window opens

One socket per user per channel; the newer one wins. That is the design.
[Connection lifecycle](connection-lifecycle.md#reconnect-policy).

## The `q` client ends with `aborted`

The actor stopped consuming. Retry only with a **new** `gameId` from your game's API.
[Dungeon](dungeon.md#finished-versus-aborted).

## `peerMoved` never fires but `snapshots` does

Peers that move appear in `pos` batches only after they are in your view; a
`snapshot` that lists nobody but you means nobody else has sent `pos` in that zone
yet. Open a second client. [Lobby](lobby.md#the-peer-map).

## `map()` throws `MapFetchException(tooLarge)`

The body exceeded 16 MiB while streaming, or 64 MiB as text. The asset is too big for
a client; ship a smaller one. [Lobby](lobby.md#the-map).

## `protocolErrors` reports "expected hello, got …"

Something answered on the lobby URL that is not the gateway's first frame. Check the
URL and the channel kind (`lobby_…` for the lobby client). [Errors](errors.md#protocol-errors).

## Works on desktop, not on web

The browser sees every handshake failure as `1006`. Confirm the token with `verify()`
and the redirect URL with the channel's allowlist. [Flutter](flutter.md#platforms).

## The app resumes from background and nothing arrives

The socket was suspended and closed; the client reconnects on `4002`. If the gateway
wrote your position less than 30 minutes ago (a move, a zone entry or an earlier
restore) it puts you back and sends a `snapshot` unasked; otherwise the peer map is empty until you send `pos`. Announce the position
you kept on every `connected`. [A retained position](lobby.md#a-retained-position),
[Flutter](flutter.md#background-and-resume).

## Every move is refused with `move_too_far` right after connecting

The gateway restored a position it retained for you, and your first `pos` — a spawn
point, or `hello.zone` with fixed coordinates — is a jump from it inside the same
zone. Resume from the position you kept, send nothing else until it is answered,
and after the refusal take your own entry in a `pos` batch as where you are.
[A retained position](lobby.md#a-retained-position).

## Nothing helps

Run the [playground](../examples/playground/README.md) offline demo. If it works there
and not against the real gateway, the difference is the four console values or the
token; if it fails there too, open an issue with the `stopped` reason and the log
lines — they carry no secret.
