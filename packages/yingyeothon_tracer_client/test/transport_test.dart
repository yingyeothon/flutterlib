import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yingyeothon_tracer_client/yingyeothon_tracer_client.dart';

import 'fake_http_client.dart';
import 'support.dart';

void main() {
  test('401 stops the client and drops what is queued', () {
    fakeAsync((async) {
      final http = FakeHttp()..answer(401);
      final c = makeClient(http);
      c.log(TracerLevel.info, 'buffered');
      c.report('a');
      c.report('b');
      async.flushMicrotasks();
      expect(c.state, TracerState.stopped);
      expect(c.enabled, isFalse);
      expect(http.sent, hasLength(1));
      // The buffered line rode in the first report's envelope.
      expect(c.stats.dropped, {'unauthorized': 2});
      String? id = 'unset';
      c.report('after').then((v) => id = v);
      c.log(TracerLevel.info, 'after');
      c.flush();
      async.elapse(const Duration(minutes: 10));
      expect(id, isNull);
      expect(http.sent, hasLength(1));
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('429 waits Retry-After, never sooner', () {
    fakeAsync((async) {
      final http = FakeHttp()..answer(429, {'retry-after': '120'});
      final c = makeClient(http);
      c.report('a');
      async.flushMicrotasks();
      c.report('b');
      async.elapse(const Duration(seconds: 119));
      expect(http.sent, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(http.sent, hasLength(3));
      expect(http.sent[1].body, http.sent[0].body, reason: 'same envelope');
      expect(c.stats.envelopesSent, 2);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('429 without a usable Retry-After waits 300 s', () {
    fakeAsync((async) {
      final http = FakeHttp()
        ..answer(429)
        ..answer(429, {'retry-after': 'Wed, 21 Oct 2026 07:28:00 GMT'});
      makeClient(http).report('a');
      async.elapse(const Duration(seconds: 299));
      expect(http.sent, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(http.sent, hasLength(2));
      async.elapse(const Duration(seconds: 299));
      expect(http.sent, hasLength(2));
      async.elapse(const Duration(seconds: 1));
      expect(http.sent, hasLength(3));
    });
  });

  test('a Retry-After past a day is capped at a day', () {
    fakeAsync((async) {
      final http = FakeHttp()..answer(503, {'retry-after': '999999'});
      makeClient(http).report('a');
      async.elapse(const Duration(hours: 24) - const Duration(seconds: 1));
      expect(http.sent, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(http.sent, hasLength(2));
    });
  });

  test('Retry-After: 0 is treated as absent, never a hot loop', () {
    fakeAsync((async) {
      final http = FakeHttp()
        ..answer(503, {'retry-after': '0'})
        ..answer(429, {'retry-after': '0'});
      makeClient(http).report('a');
      async.flushMicrotasks();
      expect(http.sent, hasLength(1));
      async.elapse(const Duration(milliseconds: 750));
      expect(http.sent, hasLength(2));
      async.elapse(const Duration(seconds: 299));
      expect(http.sent, hasLength(2));
      async.elapse(const Duration(seconds: 1));
      expect(http.sent, hasLength(3));
    });
  });

  test('the deadline grows by a second per 64 KiB of body', () {
    fakeAsync((async) {
      final http = FakeHttp()..stall();
      final c = makeClient(http, compress: false);
      c.report(
        'big',
        attachments: [
          TracerAttachment(filename: 'b', bytes: Uint8List(10 << 16)),
        ],
      );
      // 30 s + 10 s for 640 KiB, then a 0.75 s back-off.
      async.elapse(const Duration(milliseconds: 40700));
      expect(http.sent, hasLength(1));
      async.elapse(const Duration(milliseconds: 100));
      expect(http.sent, hasLength(2));
      c.close();
      async.elapse(const Duration(minutes: 2));
    });
  });

  test('503 honours Retry-After when present', () {
    fakeAsync((async) {
      final http = FakeHttp()..answer(503, {'retry-after': '60'});
      makeClient(http).report('a');
      async.elapse(const Duration(seconds: 59));
      expect(http.sent, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(http.sent, hasLength(2));
    });
  });

  test('503 without Retry-After backs off with jitter, doubling', () {
    fakeAsync((async) {
      final http = FakeHttp()
        ..answer(503)
        ..answer(500)
        ..answer(503);
      // jitter 0.5 → 0.75 × (1 s, 2 s, 4 s).
      makeClient(http).report('a');
      async.elapse(const Duration(milliseconds: 749));
      expect(http.sent, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      expect(http.sent, hasLength(2));
      async.elapse(const Duration(milliseconds: 1499));
      expect(http.sent, hasLength(2));
      async.elapse(const Duration(milliseconds: 1));
      expect(http.sent, hasLength(3));
      async.elapse(const Duration(milliseconds: 3000));
      expect(http.sent, hasLength(4));
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('jitter edges: 0 gives half the delay, 0.999999 nearly all', () {
    for (final (jitter, before) in [(0.0, 499), (0.999999, 999)]) {
      fakeAsync((async) {
        final http = FakeHttp()..answer(503);
        makeClient(http, jitter: jitter).report('a');
        async.elapse(Duration(milliseconds: before));
        expect(http.sent, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(http.sent, hasLength(2));
      });
    }
  });

  test('the back-off stops growing at five minutes', () {
    fakeAsync((async) {
      final http = FakeHttp();
      for (var i = 0; i < 12; i++) {
        http.answer(503);
      }
      // Nearly full jitter: 1 + 2 + … + 256 s, then 300 s three times.
      makeClient(http, jitter: 0.999999).report('a');
      async.elapse(const Duration(seconds: 1410));
      expect(http.sent, hasLength(12));
      async.elapse(const Duration(seconds: 1));
      expect(http.sent, hasLength(13));
    });
  });

  test('a network error or timeout backs off and keeps the envelope', () {
    fakeAsync((async) {
      final http = FakeHttp()
        ..fail(const SocketException('down'))
        ..stall();
      final c = makeClient(http);
      c.report('a');
      async.elapse(const Duration(milliseconds: 750));
      expect(http.sent, hasLength(2));
      // The stalled request times out at 30 s, then backs off 1.5 s.
      async.elapse(const Duration(seconds: 30));
      expect(http.sent, hasLength(2));
      async.elapse(const Duration(milliseconds: 1500));
      expect(http.sent, hasLength(3));
      expect(c.stats.envelopesSent, 1);
      expect(c.stats.dropped, isEmpty);
    });
  });

  test('400, 413 and an unexpected 4xx drop and count', () {
    fakeAsync((async) {
      final http = FakeHttp()
        ..answer(400)
        ..answer(413)
        ..answer(404);
      final c = makeClient(http);
      c
        ..report('a')
        ..report('b')
        ..report('c')
        ..report('d');
      async.flushMicrotasks();
      expect(http.sent, hasLength(4));
      expect(c.stats.dropped, {'invalid': 1, 'too_large': 1, 'http_404': 1});
      expect(c.stats.envelopesSent, 1);
    });
  });

  test('415 resends once without gzip, then drops', () {
    fakeAsync((async) {
      final http = FakeHttp()
        ..answer(415)
        ..answer(415);
      final c = makeClient(http);
      c.report('a');
      async.flushMicrotasks();
      expect(http.sent.map((s) => s.request.headers['content-encoding']), [
        'gzip',
        null,
      ]);
      expect(c.stats.dropped, {'encoding': 1});
      c.report('b');
      async.flushMicrotasks();
      expect(http.sent.last.request.headers['content-encoding'], isNull);
    });
  });

  test('the queue is bounded: the oldest envelope makes room', () {
    fakeAsync((async) {
      final http = FakeHttp()..answer(503, {'retry-after': '10'});
      final c = makeClient(http, maxQueuedEnvelopes: 2);
      c.report('first');
      async.flushMicrotasks();
      c
        ..report('second')
        ..report('third');
      expect(c.stats.queued, 2);
      expect(c.stats.dropped, {'queue_full': 1});
      async.elapse(const Duration(seconds: 10));
      expect(http.sent.map((s) => s.parsed.items.first.json['message']), [
        'first',
        'second',
        'third',
      ]);
    });
  });

  test('the byte bound drops the oldest but keeps the newest', () {
    fakeAsync((async) {
      final http = FakeHttp()..answer(503, {'retry-after': '10'});
      final c = makeClient(http, maxQueuedBytes: 1);
      c
        ..report('a')
        ..report('b');
      async.flushMicrotasks();
      expect(c.stats.queued, 1);
      expect(c.stats.dropped, {'queue_full': 1});
      async.elapse(const Duration(seconds: 10));
      expect(c.stats.envelopesSent, 1);
    });
  });

  test('flush returns when the queue drains, or at once while paused', () {
    fakeAsync((async) {
      final http = FakeHttp()..answer(503, {'retry-after': '30'});
      final c = makeClient(http);
      c.log(TracerLevel.info, 'x');
      var flushed = false;
      c.flush().then((_) => flushed = true);
      async.flushMicrotasks();
      expect(flushed, isTrue, reason: 'paused by the 503, not waiting');
      c.log(TracerLevel.info, 'y');
      flushed = false;
      c.flush().then((_) => flushed = true);
      async.flushMicrotasks();
      expect(flushed, isTrue);
      expect(http.sent, hasLength(1));
      async.elapse(const Duration(seconds: 30));
      expect(http.sent, hasLength(3));
      flushed = false;
      c.flush().then((_) => flushed = true);
      async.flushMicrotasks();
      expect(flushed, isTrue);
    });
  });

  test('close flushes, cancels every timer, and later calls are no-ops', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      c.log(TracerLevel.info, 'last words');
      var closed = false;
      c.close().then((_) => closed = true);
      async.flushMicrotasks();
      expect(closed, isTrue);
      expect(http.sent.single.parsed.items.single.type, 'log');
      expect(c.state, TracerState.closed);
      expect(async.pendingTimers, isEmpty);
      c.report('after');
      c.close();
      async.flushMicrotasks();
      expect(http.sent, hasLength(1));
      expect(http.closed, isFalse);
    });
  });

  test('close while backing off drops what is left and stops the timer', () {
    fakeAsync((async) {
      final http = FakeHttp()..answer(503);
      final c = makeClient(http);
      c.report('a');
      async.flushMicrotasks();
      c.close();
      async.flushMicrotasks();
      expect(c.stats.dropped, {'closed': 1});
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('close aborts a stalled request after its deadline', () {
    fakeAsync((async) {
      final http = FakeHttp()..stall();
      final c = makeClient(http);
      c.report('a');
      async.flushMicrotasks();
      var closed = false;
      c.close().then((_) => closed = true);
      async.elapse(const Duration(seconds: 30));
      expect(closed, isTrue);
      expect(c.stats.dropped['closed'], greaterThanOrEqualTo(1));
      async.elapse(const Duration(minutes: 5));
      expect(http.sent, hasLength(1));
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a client it built itself is closed on close', () {
    final c = TracerClient(const TracerOptions(dsn: fixtureDsn));
    expect(c.state, TracerState.active);
    expect(c.close(), completes);
  });

  test('the transport error type is not what decides the retry', () {
    fakeAsync((async) {
      final fake = FakeHttp()..fail(http.ClientException('x'));
      final c = makeClient(fake);
      c.report('a');
      async.elapse(const Duration(seconds: 1));
      expect(c.stats.envelopesSent, 1);
    });
  });
}
