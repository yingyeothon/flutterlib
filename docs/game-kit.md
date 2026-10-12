# Build a game with one kit

Paste the public project kit-config from the console, then share one kit for
identity, tuning, saves, rooms and game systems. The language-neutral contract
is the service repository's `docs/game-kit-design.md`; wire requests stay in the
individual clients. Package signatures are in the
[game kit API](../packages/yingyeothon_game_kit/README.md#public-api).

## Start the session

```dart
import 'package:yingyeothon_game_kit/yingyeothon_game_kit.dart';

final kit = GameKit(GameKitOptions(config: GameKitConfig(publicConfig)));
await kit.session.fromToken(jwt);
```

`fromToken` reads claims; the service verifies requests. Supply a host login
callback for `signIn`, and optionally a secure storage adapter for `restore`.
Platform redirects stay in the host app. The web default is memory-only.
`now()` is platform epoch milliseconds; expiry is epoch seconds. An unavailable
server clock is an error, never a fallback to device wall time. Watch `expiring`
for reauthentication and `signedOut` to return to sign-in; any module's 401
stops every module.

## Content and saves

```dart
final tuning = await kit.content.get('tuning');
await kit.save.load('progress');
await kit.save.store('progress', {'level': 2}, merge: (local, remote) {
  final a = (local as Map)['level'] as int;
  final b = (remote as Map?)?['level'] as int? ?? 0;
  return {'level': a > b ? a : b};
});
final rewarded = await kit.save.claimOnce('daily', 86400);
await kit.save.counter('coins').add(-1, min: 0);
```

Content returns cached values and refreshes them in foreground; its watcher
compares entry versions because the state API has no conditional 304 reads.
Save writes are conditional; conflict requires an explicit game merge policy.
A mobile queue needs a durable adapter and registered merge policies for reload.
It excludes counters/claims. Failed replay keeps its record and stops.

## Rooms and deterministic turns

```dart
await kit.room.connect();
await kit.room.create();
kit.room.invited.listen((invite) async { await invite.accept(); });
kit.room.events.listen((event) { /* Validate/render the game's event. */ });
await kit.room.publish({'hp': 7}); // host only
final game = await kit.turns.start(
  initial: 0,
  apply: (state, move, by) => (state as int) + (move as int),
  persist: true,
  saveResultAs: 'last-result',
);
```

Every peer supplies the same player order and initial state. Submit only on your
turn; a hash/reducer divergence freezes with `mismatch`. Host authority is
**by agreement**, not server arbitration. The authenticated gateway sender is
used for moves and snapshots. State and logs are recovered after reconnect;
finish waits for validated recovery before recording each player's own result.
Large logs are chunked; oversized game snapshots use game-defined deltas.
Subscribe before commands that may synchronously produce events, and cancel
subscriptions when their screen closes.

## Boards, inbox and friends

```dart
await kit.board('weekly').submit(12);
final nearby = await kit.board('weekly').around('weekly');
kit.mail.arrived.listen((letter) { /* Show the unread letter. */ });
final reward = await kit.mail.claim(letterId);
await kit.friends.request(friendId);
final friends = await kit.friends.list();
```

Board aliases come from config; server-only boards refuse player writes.
`claim` returns a letter to exactly one successful conditional deleter; the game
applies its reward. Player mail is create-only and carries the platform writer
stamp. Mail and incoming requests poll only in foreground. Friend presence is
batched and is a hint, not authorization. Validate peer display names in the UI.

## Live and deferred matching

```dart
await kit.room.connect();
final matched = await kit.matchmaking.find(); // live config
// With match.mode == "deferred":
final ticket = await kit.matchmaking.submit();
kit.matchmaking.stateChanged.listen((status) { /* Offer accept/decline. */ });
```

Live find requires the shared lobby. Without a callback, the lowest matched user
creates a room; matched-member invites are accepted within the formation window.
A partial result lists only members who joined. Configure `matchCallback: true`
for a callback channel; null callback results are never used to infer its mode.

Deferred matching uses tickets without a lobby. Read `status()` after session
restoration to observe an existing ticket. Waiting/proposed tickets enable
polling, and push/resume reads fresh state. Requests are paced, retries release
the request lane, and cancellation prevents a delayed submit from creating a new
ticket after the caller canceled. Terminal statuses stop polling. Wakes are hints
and always lead to HTTP verification.

## Android push and lifecycle

Supply the app's `PushMessaging` adapter and embedded Firebase project id, then
call `kit.push.start()` at startup. The
[playground adapter](../examples/playground/lib/push/firebase_push_messaging.dart)
handles foreground, tap and cold-start notification messages. Broadcast topics
are public and copied from kit-config. Device tokens go only to registration;
the kit never exposes server send/campaign endpoints. iOS is unsupported.

Wire `setForeground` to mobile pause/resume and browser visibility. Keep the kit
alive while backgrounded so deferred push can wake it on resume; use `close`
when the owner is finished with it. Sign-out immediately invalidates pending
work and unregisters push with the former credential. A replacement registration
waits for the old topic cleanup.

## Verify the integration

The [playground](../examples/playground) includes an offline Game kit screen
and `YYT_OFFLINE_AUTOSTART_GAME_KIT=true` for the same walk from a Linux terminal.
It exercises all waves against loopback fakes. Unit scenarios use injectable
transports, clocks and durable storage, and cover adversarial replay and identity
changes. Dev authentication and Android FCM receipt are separate environment
checks; fake success is not a real-device receipt.
