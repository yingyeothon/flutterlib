import 'package:test/test.dart';
import 'package:yingyeothon_event_broker/yingyeothon_event_broker.dart';

class Ping {
  const Ping(this.n);
  final int n;
}

class Base {}

class Derived extends Base {}

void main() {
  test('handlers run in registration order and fire reports true', () async {
    final broker = EventBroker();
    final seen = <String>[];
    broker
      ..on<Ping>((e) => seen.add('a${e.n}'))
      ..on<Ping>((e) async {
        await Future<void>.delayed(Duration.zero);
        seen.add('b${e.n}');
      })
      ..on<Ping>((e) => seen.add('c${e.n}'));
    expect(await broker.fire(const Ping(1)), isTrue);
    expect(seen, ['a1', 'b1', 'c1']);
  });

  test('fire with no handler reports false', () async {
    expect(await EventBroker().fire(const Ping(0)), isFalse);
  });

  test('handlers are keyed by static type, not runtime type', () async {
    final broker = EventBroker();
    final seen = <String>[];
    broker
      ..on<Base>((_) => seen.add('base'))
      ..on<Derived>((_) => seen.add('derived'));
    await broker.fire<Base>(Derived());
    expect(seen, ['base']);
    await broker.fire(Derived());
    expect(seen, ['base', 'derived']);
  });

  test('once is removed before it runs, even when it throws', () async {
    final broker = EventBroker();
    var calls = 0;
    broker.once<Ping>((_) {
      calls++;
      throw StateError('boom');
    });
    await expectLater(broker.fire(const Ping(1)), throwsStateError);
    expect(await broker.fire(const Ping(2)), isFalse);
    expect(calls, 1);
  });

  test('the first throwing handler stops the fire', () async {
    final broker = EventBroker();
    final seen = <int>[];
    broker
      ..on<Ping>((e) => seen.add(1))
      ..on<Ping>((e) => throw StateError('stop'))
      ..on<Ping>((e) => seen.add(3));
    await expectLater(broker.fire(const Ping(0)), throwsStateError);
    expect(seen, [1]);
  });

  test('a fire runs over a snapshot', () async {
    final broker = EventBroker();
    final seen = <String>[];
    void late(Ping e) => seen.add('late');
    broker.on<Ping>((e) {
      broker.on<Ping>(late);
      seen.add('first');
    });
    await broker.fire(const Ping(0));
    expect(seen, ['first']);
    await broker.fire(const Ping(1));
    expect(seen, ['first', 'first', 'late']);
  });

  test('off removes the first matching registration only', () async {
    final broker = EventBroker();
    var calls = 0;
    void handler(Ping e) => calls++;
    broker
      ..on<Ping>(handler)
      ..on<Ping>(handler)
      ..off<Ping>(handler);
    await broker.fire(const Ping(0));
    expect(calls, 1);
    broker.off<Ping>(handler);
    broker.off<Ping>(handler); // no registration left: a no-op
    expect(await broker.fire(const Ping(0)), isFalse);
  });
}
