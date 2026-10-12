import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';

void main() {
  test('proposal accepts all members into one immutable match result', () {
    var now = 100;
    final store = FakeMatchStore(clock: () => now);
    expect(store.submit('a')['state'], 'waiting');
    store.submit('b');
    expect(store.status('a')!['state'], 'proposed');
    expect(
      () => store.submit('a'),
      throwsA(
        isA<FakeMatchRefusal>().having((e) => e.reason, 'reason', 'proposed'),
      ),
    );
    expect(store.accept('a')['state'], 'proposed');
    expect(store.accept('b')['state'], 'confirmed');
    expect(store.status('a'), store.status('b'));
    expect(store.accept('a')['state'], 'confirmed');
    expect(
      () => store.decline('a'),
      throwsA(
        isA<FakeMatchRefusal>().having((e) => e.reason, 'reason', 'confirmed'),
      ),
    );
    store.cancel('a');
    expect(store.status('a'), null);
    store.cancel('a');
    now += 100;
  });
  test('decliner cooldown and other players return to waiting', () {
    var now = 100;
    final store = FakeMatchStore(clock: () => now);
    store.submit('a');
    store.submit('b');
    expect(store.decline('a')['state'], 'declined');
    expect(store.decline('a')['state'], 'declined');
    expect(store.status('b')!['state'], 'waiting');
    expect(
      () => store.submit('a'),
      throwsA(isA<FakeMatchRefusal>().having((e) => e.retryAfter, 'retry', 30)),
    );
    now += 30;
    store.submit('a');
    expect(store.status('a')!['state'], 'proposed');
    store.cancel('a');
    expect(store.status('a'), null);
  });
  test('wait and accept deadlines distinguish states and failed callbacks', () {
    var now = 100;
    final store = FakeMatchStore(clock: () => now);
    store.submit('a');
    now += 60;
    expect(store.status('a')!['reason'], 'wait');
    store.submit('b');
    store.submit('c');
    store.accept('b');
    now += 30;
    expect(store.status('c')!['reason'], 'accept');
    expect(store.status('b')!['state'], 'waiting');
    store.fail('b');
    expect(store.status('b')!['state'], 'failed');
    store.submit('d');
    store.submit('e');
    store.fail('d', reason: 'closed');
    expect(store.status('e')!['reason'], 'closed');
    expect(() => store.fail('x', reason: 'invalid'), throwsArgumentError);
    expect(() => store.accept('none'), throwsA(isA<FakeMatchRefusal>()));
    expect(() => store.decline('none'), throwsA(isA<FakeMatchRefusal>()));
    expect(() => store.accept('c'), throwsA(isA<FakeMatchRefusal>()));
    expect(() => store.decline('c'), throwsA(isA<FakeMatchRefusal>()));
    expect(() => FakeMatchStore(partySize: 1), throwsArgumentError);
  });
  test('proposal survivors retain FIFO order and waiting age', () {
    var now = 100;
    final store = FakeMatchStore(clock: () => now, partySize: 3);
    store.submit('a');
    now = 110;
    store.submit('b');
    now = 120;
    store.submit('c');
    now = 140;
    store.decline('a');
    expect(store.status('b')!['position'], 1);
    expect(store.status('b')!['waited'], 30);
    now = 141;
    store.submit('d');
    store.accept('b');
    store.accept('c');
    expect(store.accept('d')['members'], [
      {'userId': 'b'},
      {'userId': 'c'},
      {'userId': 'd'},
    ]);
  });
  test(
    'one token transfers ownership within a channel but not across channels',
    () {
      final push = FakePushStore(tokenCap: 1);
      push.register('a', 'device', 'demo-project', now: 0);
      expect(push.register('b', 'device', 'demo-project', now: 1), null);
      expect(push.contains('a', 'device'), false);
      expect(push.contains('b', 'device'), true);
      push.unregister('a', 'device');
      expect(push.tokenCount, 1);
      expect(
        push.register(
          'a',
          'device',
          'demo-project',
          now: 1,
          channel: 'push_other',
        ),
        null,
      );
      expect(push.tokenCount, 2);
    },
  );
  test('token refresh, per-user eviction, channel cap and sixty-day sweep', () {
    final push = FakePushStore(tokenCap: 10);
    expect(push.register('a', 't1', 'demo-project', now: 1), null);
    expect(push.contains('a', 't1'), true);
    expect(push.tokenCount, 1);
    push.unregister('b', 't1');
    expect(push.contains('a', 't1'), true);
    push.register('a', 't1', 'demo-project', now: 2);
    expect(push.tokenCount, 1);
    for (var n = 2; n <= 6; n++) {
      push.register('a', 't$n', 'demo-project', now: 3);
    }
    expect(push.tokenCount, 5);
    expect(push.contains('a', 't1'), false);
    push.unregister('a', 't2');
    expect(push.tokenCount, 4);
    push.sweep(60 * 86400 + 3);
    expect(push.tokenCount, 4);
    push.sweep(60 * 86400 + 4);
    expect(push.tokenCount, 0);
    final full = FakePushStore(tokenCap: 1);
    full.register('a', 't', 'demo-project', now: 0);
    expect(full.register('b', 'x', 'demo-project', now: 0), 'channel_full');
    expect(full.register('a', 't', 'demo-project', now: 1), null);
  });
  test('per-user eviction replaces a token even at the channel cap', () {
    final push = FakePushStore(tokenCap: 5);
    for (var n = 1; n <= 5; n++) {
      expect(push.register('a', 't$n', 'demo-project', now: n), null);
    }
    expect(push.register('a', 't6', 'demo-project', now: 6), null);
    expect(push.tokenCount, 5);
    expect(push.contains('a', 't1'), false);
  });
  test('token registration refusals match the service error words', () {
    final push = FakePushStore(projects: {'first', 'second'});
    expect(push.register('a', 't', null, now: 0), 'push_project_required');
    expect(push.register('a', 't', 'other', now: 0), 'push_project_refused');
    expect(push.register('a', '', null, now: 0), 'bad_request');
    expect(push.register('a', 'bad token', null, now: 0), 'bad_request');
    expect(push.register('a', 'a' * 513, null, now: 0), 'bad_request');
    expect(
      FakePushStore(projects: {}).register('a', 't', null, now: 0),
      'push_not_registered',
    );
    expect(FakePushStore().register('a', 't', null, now: 0), null);
    expect(FakePushStore.handles('/push/ch/token'), true);
    expect(FakePushStore.handles('/kv/c'), false);
  });
}
