// The client over a real `package:http` client against a loopback server:
// the fake gateway's `/kv/*` routes, and, when `YYT_KV_BASE_URL` and
// `YYT_KV_TOKEN` are set, the dev state stack too (a `profile`-shaped
// collection named by `YYT_KV_PROFILE`, an `announcements`-shaped one by
// `YYT_KV_ANNOUNCEMENTS`). Neither value is ever printed.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_kvstore_client/yingyeothon_kvstore_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

Future<T> soon<T>(Future<T> f) => f.timeout(const Duration(seconds: 10));

/// Captures formatted lines.
final class CapturingLogWriter implements LogWriter {
  final List<String> lines = <String>[];
  void _add(LogSeverity s, String m, JsonObject? c) =>
      lines.add(LogWriters.format(s, m, c));
  @override
  void debug(String message, [JsonObject? context]) =>
      _add(LogSeverity.debug, message, context);
  @override
  void info(String message, [JsonObject? context]) =>
      _add(LogSeverity.info, message, context);
  @override
  void warn(String message, [JsonObject? context]) =>
      _add(LogSeverity.warn, message, context);
  @override
  void error(String message, [JsonObject? context]) =>
      _add(LogSeverity.error, message, context);
}

/// The two cases the guide shows, against any server that follows the
/// contract. [announcements] is readable and not writable by a player;
/// [profile] is a user namespace the player owns.
Future<void> walkTheTwoCases(
  KvStoreClient kv, {
  required String announcements,
  required String profile,
}) async {
  // (1) announcements: list newest first, with values.
  final notices = await soon(
    kv.collection(announcements).list(values: true, order: KvOrder.desc),
  );
  expect(notices.entries, isNotEmpty);
  expect(notices.entries.every((e) => e.hasValue), isTrue);
  expect(
    () => kv.collection(announcements).put('x', 1),
    throwsA(
      isA<KvStoreException>().having((e) => e.isForbidden, 'forbidden', isTrue),
    ),
  );

  // (2) my record: read, merge, write, read back, delete.
  final mine = kv.collection(profile).mine;
  final key = 'it-${DateTime.now().millisecondsSinceEpoch}';
  await soon(mine.delete(key));
  expect(await soon(mine.get(key, orElse: () => null)), isNull);
  final saved =
      await soon(mine.get(key, orElse: () => null)) as Map<String, Object?>?;
  final created = await soon(
    mine.put(key, <String, Object?>{
      ...?saved,
      'volume': 0.5,
    }, ifNoneMatch: true),
  );
  expect(created.created, isTrue);
  expect(created.version, isNotNull);
  final entry = await soon(mine.getEntry(key));
  expect(entry!.value, <String, Object?>{'volume': 0.5});
  expect(entry.version, created.version);
  final updated = await soon(
    mine.put(
      key,
      <String, Object?>{'volume': 1},
      ifMatch: entry.version,
      ttl: 60,
    ),
  );
  expect(updated.created, isFalse);
  expect(updated.version, entry.version + 1);
  expect(updated.expiresAt, isNotNull);
  final stale = await mine
      .put(key, <String, Object?>{}, ifMatch: entry.version)
      .then<KvStoreException?>(
        (_) => null,
        onError: (Object e) => e as KvStoreException,
      );
  expect(stale!.isConflict, isTrue);
  expect(stale.hasCurrentVersion, isTrue);
  expect(stale.currentVersion, updated.version);
  final page = await soon(mine.list(prefix: 'it-', values: true));
  expect(page.entries.map((e) => e.key), contains(key));
  final counter = await soon(mine.incr('$key-hits', 2));
  expect(counter.value, 2);
  await soon(mine.delete(key, ifMatch: updated.version));
  await soon(mine.delete('$key-hits'));
  expect(await soon(mine.getEntry(key)), isNull);
}

void main() {
  group('against the fake gateway', () {
    late FakeGateway gw;
    late CapturingLogWriter log;
    late KvStoreClient kv;

    setUp(() async {
      gw = await FakeGateway.start(
        options: const FakeGatewayOptions(
          kvCollections: <FakeKvCollection>[
            FakeKvCollection(
              name: 'announcements',
              readScope: 'project',
              writeScope: 'team',
              entries: <String, Object?>{
                '2026-09-01': <String, Object?>{'title': 'Welcome'},
              },
            ),
            FakeKvCollection(
              name: 'profile',
              readScope: 'user',
              writeScope: 'user',
            ),
          ],
        ),
      );
      log = CapturingLogWriter();
      kv = KvStoreClient(
        KvStoreClientOptions(
          baseUrl: gw.kvUrl,
          token: 'eyJ.secret-token.sig',
          logger: createFilteredLogger(
            severity: LogSeverity.debug,
            writer: log,
          ),
        ),
      );
    });

    tearDown(() async {
      kv.close();
      await gw.shutdown();
    });

    test('the two cases round-trip over a real http client', () async {
      await walkTheTwoCases(
        kv,
        announcements: 'announcements',
        profile: 'profile',
      );
      expect(
        gw.kv.valueText('profile', 'never', owner: 'eyJ.secret-token.sig'),
        isNull,
      );
      // Positive control, then the negative: the token is in no log line.
      expect(log.lines.first, contains('kv request'));
      expect(log.lines.join('\n'), isNot(contains('secret-token')));
      expect(log.lines.join('\n'), isNot(contains('127.0.0.1')));
    });

    test('info, a 404 collection and a closed listener', () async {
      final info = await soon(kv.collection('profile').info());
      expect(info.writeScope, KvScope.user);
      expect(info.isUserNamespace, isTrue);
      final missing = await kv
          .collection('nope')
          .info()
          .then<KvStoreException?>(
            (_) => null,
            onError: (Object e) => e as KvStoreException,
          );
      expect(missing!.isNotFound, isTrue);
      await gw.shutdown();
      final gone = await kv
          .collection('profile')
          .info()
          .then<KvStoreException?>(
            (_) => null,
            onError: (Object e) => e as KvStoreException,
          );
      expect(gone!.status, 0);
      expect(gone.code, KvStoreException.networkCode);
    });
  });

  group('against the dev state stack', () {
    final env = Platform.environment;
    final baseUrl = env['YYT_KV_BASE_URL'];
    final token = env['YYT_KV_TOKEN'];

    test(
      'the two cases round-trip on dev',
      () async {
        final kv = KvStoreClient(
          KvStoreClientOptions(baseUrl: Uri.parse(baseUrl!), token: token!),
        );
        addTearDown(kv.close);
        await walkTheTwoCases(
          kv,
          announcements: env['YYT_KV_ANNOUNCEMENTS'] ?? 'announcements',
          profile: env['YYT_KV_PROFILE'] ?? 'profile',
        );
      },
      skip: baseUrl == null || token == null
          ? 'set YYT_KV_BASE_URL and YYT_KV_TOKEN to run against dev'
          : null,
    );
  });
}
