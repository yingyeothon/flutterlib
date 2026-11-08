import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';
import 'package:yingyeothon_tracer_client/yingyeothon_tracer_client.dart';

import 'fake_http_client.dart';
import 'support.dart';

class _Unprintable {
  @override
  String toString() => throw StateError('no');
}

void main() {
  test('an empty or bad DSN is off: no request, no throw, null ids', () {
    for (final dsn in ['', '  ', 'https://short@trace.invalid/trc_a1']) {
      final http = FakeHttp();
      final c = makeClient(http, dsn: dsn);
      expect(c.state, TracerState.off);
      expect(c.enabled, isFalse);
      c
        ..breadcrumb('ui', 'tap')
        ..log(TracerLevel.info, 'x')
        ..trace('ui', 'y')
        ..setTag('a', 'b');
      fakeAsync((async) {
        String? id = 'unset';
        c.report('r').then((v) => id = v);
        async.flushMicrotasks();
        expect(id, isNull);
        c.feedback('n').then((v) => id = v);
        async.flushMicrotasks();
        expect(id, isNull);
        c.flush();
        c.close();
        async.elapse(const Duration(minutes: 1));
      });
      expect(http.sent, isEmpty);
    }
  });

  test('a bad DSN is logged without the DSN', () {
    final writer = CapturingLogWriter();
    makeClient(
      FakeHttp(),
      dsn: 'https://quotedsecretquoted@trace.invalid/nope',
      logger: createFilteredLogger(severity: LogSeverity.debug, writer: writer),
    );
    expect(writer.lines, ['[warn] tracer off: DSN did not parse']);
  });

  test('request: route, auth header, content type, gzip', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      c.report('hello');
      async.flushMicrotasks();
      final r = http.sent.single.request;
      expect(r.method, 'POST');
      expect(
        r.url.toString(),
        'https://trace.invalid/api/trc_fixture01/envelope/',
      );
      expect(
        r.headers['x-sentry-auth'],
        'Sentry sentry_key=$fixtureKey, sentry_version=7, '
        'sentry_client=yyt-dart/$tracerSdkVersion',
      );
      expect(r.headers['content-type'], 'application/x-sentry-envelope');
      expect(r.headers['content-encoding'], 'gzip');
      expect(r.followRedirects, isFalse);
      expect(gzip.decode(r.bodyBytes), http.sent.single.body);
      expect(c.stats.envelopesSent, 1);
    });
  });

  test('compress: false sends the envelope plain', () {
    fakeAsync((async) {
      final http = FakeHttp();
      makeClient(http, compress: false).report('hello');
      async.flushMicrotasks();
      final r = http.sent.single.request;
      expect(r.headers.containsKey('content-encoding'), isFalse);
      expect(r.bodyBytes, http.sent.single.body);
    });
  });

  test('event: correlation fields, breadcrumbs, tags, sdk', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http, tags: {'git_sha': 'abc1234'});
      c
        ..setTag('feature', 'board')
        ..setTag('gone', 'x')
        ..setTag('gone', null)
        ..breadcrumb(
          'ui',
          'tap',
          data: {'button': 'ok', 'when': DateTime.utc(2026), 'nan': double.nan},
        )
        ..breadcrumb('nav', 'push', level: TracerLevel.debug);
      String? id;
      c.report('looks wrong', data: {'move': 'e2e4'}).then((v) => id = v);
      async.flushMicrotasks();
      final env = http.sent.single.parsed;
      expect(env.header['event_id'], id);
      expect(env.header['sdk'], {
        'name': 'yyt.dart',
        'version': tracerSdkVersion,
      });
      expect(env.header['sent_at'], isA<String>());
      expect(env.header.containsKey('dsn'), isFalse);
      expect(env.items.map((i) => i.type), ['event']);
      final e = env.items.single.json;
      expect(e['event_id'], id);
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(e['level'], 'warning');
      expect(e['platform'], 'dart');
      expect(e['message'], 'looks wrong');
      expect(e['release'], 'playground@0.1.0+1');
      expect(e['dist'], 'abc1234');
      expect(e['environment'], 'debug');
      expect(e['user'], {'id': '00000000000000000000000000000000'});
      expect(e['tags'], {'git_sha': 'abc1234', 'feature': 'board'});
      expect(e['extra'], {'move': 'e2e4'});
      final trace = (e['contexts']! as Map)['trace'] as Map;
      expect(trace['trace_id'], c.traceId);
      expect(trace['span_id'], matches(RegExp(r'^[0-9a-f]{16}$')));
      final crumbs = (e['breadcrumbs']! as Map)['values'] as List;
      expect(crumbs, hasLength(2));
      expect(crumbs.first, {
        'timestamp': isA<String>(),
        'type': 'default',
        'category': 'ui',
        'level': 'info',
        'message': 'tap',
        'data': {
          'button': 'ok',
          'when': '2026-01-01T00:00:00.000Z',
          'nan': 'NaN',
        },
      });
      expect((crumbs.last as Map)['level'], 'debug');
      expect((crumbs.last as Map).containsKey('data'), isFalse);
      expect(DateTime.parse(e['timestamp']! as String).isUtc, isTrue);
    });
  });

  test('the ring keeps the newest breadcrumbs, 500 by default', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http, breadcrumbCapacity: 3);
      for (var i = 0; i < 5; i++) {
        c.breadcrumb('n', '$i');
      }
      c.report('r');
      final d = makeClient(http);
      for (var i = 0; i < 501; i++) {
        d.breadcrumb('n', '$i');
      }
      d.report('r');
      async.flushMicrotasks();
      List<Object?> crumbs(int n) =>
          ((http.sent[n].parsed.items.first.json['breadcrumbs']!
                      as Map)['values']
                  as List)
              .map((b) => (b as Map)['message'])
              .toList();
      expect(crumbs(0), ['2', '3', '4']);
      expect(crumbs(1), hasLength(500));
      expect(crumbs(1).first, '1');
    });
  });

  test('an event over 1 MiB drops its oldest breadcrumbs, then extra', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      final big = 'x' * 8000;
      for (var i = 0; i < 500; i++) {
        c.breadcrumb('n', '$i $big');
      }
      c.report('r', data: {'a': big});
      final d = makeClient(http, breadcrumbCapacity: 0);
      d.breadcrumb('n', 'ignored');
      d.report('r', data: {for (var i = 0; i < 200; i++) '$i': big});
      async.flushMicrotasks();
      final first = http.sent[0].parsed.items.first;
      expect(
        first.payload.length,
        lessThanOrEqualTo(TracerLimits.maxJsonItemBytes),
      );
      final crumbs = (first.json['breadcrumbs']! as Map)['values'] as List;
      expect(crumbs.length, inExclusiveRange(1, 500));
      expect(((crumbs.last as Map)['message'] as String), startsWith('499 '));
      expect(first.json['extra'], isNotNull);
      final second = http.sent[1].parsed.items.first;
      expect(second.json['extra'], {'tracer.truncated': true});
      expect((second.json['breadcrumbs']! as Map)['values'], isEmpty);
    });
  });

  test('report with an error: exception with frames, oldest first', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      c.report(
        'failed',
        error: StateError('bad move'),
        stackTrace: StackTrace.fromString(
          '#0      Board.move (package:app/board.dart:10:5)\n'
          '#1      List.forEach (dart:core-patch/growable_array.dart:417:8)\n'
          '#2      main (file:///app/main.dart:3)\n'
          '#3      run (file:///srv/app/lib/src/run.dart:9:1)\n'
          'not a frame\n',
        ),
        level: TracerLevel.error,
      );
      c.report('no trace', error: _Unprintable());
      async.flushMicrotasks();
      final e = http.sent[0].parsed.items.first.json;
      expect(e['level'], 'error');
      final value = ((e['exception']! as Map)['values'] as List).single as Map;
      expect(value['type'], 'StateError');
      expect(value['value'], 'Bad state: bad move');
      expect((value['stacktrace']! as Map)['frames'], [
        {
          'filename': 'src/run.dart',
          'function': 'run',
          'lineno': 9,
          'colno': 1,
          'abs_path': 'file:///srv/app/lib/src/run.dart',
          'in_app': true,
          'platform': 'dart',
        },
        {
          'filename': 'main.dart',
          'function': 'main',
          'lineno': 3,
          'abs_path': 'file:///app/main.dart',
          'in_app': true,
          'platform': 'dart',
        },
        {
          'filename': 'dart:core-patch/growable_array.dart',
          'function': 'List.forEach',
          'lineno': 417,
          'colno': 8,
          'abs_path': 'dart:core-patch/growable_array.dart',
          'in_app': false,
          'platform': 'dart',
        },
        {
          'filename': 'app/board.dart',
          'package': 'app',
          'function': 'Board.move',
          'lineno': 10,
          'colno': 5,
          'abs_path': 'package:app/board.dart',
          'in_app': true,
          'platform': 'dart',
        },
      ]);
      final f = http.sent[1].parsed.items.first.json;
      final v2 = ((f['exception']! as Map)['values'] as List).single as Map;
      expect(v2, {'type': '_Unprintable', 'value': '<unprintable>'});
    });
  });

  test('attachments: screenshot first, header fields, 20 per envelope', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      c.report(
        'r',
        screenshot: png,
        attachments: [
          TracerAttachment.viewHierarchy(utf8.encode('{"windows":[]}')),
          for (var i = 0; i < 19; i++)
            TracerAttachment(filename: 'f$i.txt', bytes: Uint8List(1)),
        ],
      );
      async.flushMicrotasks();
      final items = http.sent.single.parsed.items;
      expect(items.where((i) => i.type == 'attachment'), hasLength(20));
      expect(items[1].header, {
        'type': 'attachment',
        'filename': 'screenshot.png',
        'content_type': 'image/png',
        'attachment_type': 'event.attachment',
        'length': 4,
      });
      expect(items[1].payload, png);
      expect(items[2].header, {
        'type': 'attachment',
        'filename': 'view-hierarchy.json',
        'content_type': 'application/json',
        'attachment_type': 'event.view_hierarchy',
        'length': 14,
      });
      expect(items.last.header['content_type'], 'application/octet-stream');
      expect(c.stats.dropped, {'too_large': 1});
    });
  });

  test('an attachment that would pass 20 MiB is dropped, the rest sent', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http, maxQueuedBytes: 64 << 20);
      c.report(
        'r',
        attachments: [
          TracerAttachment(filename: 'a', bytes: Uint8List(12 << 20)),
          TracerAttachment(filename: 'b', bytes: Uint8List(12 << 20)),
          TracerAttachment(filename: 'c', bytes: Uint8List(1)),
        ],
      );
      async.flushMicrotasks();
      final env = http.sent.single;
      expect(env.parsed.items.map((i) => i.header['filename']), [
        null,
        'a',
        'c',
      ]);
      expect(env.body.length, lessThanOrEqualTo(TracerLimits.maxEnvelopeBytes));
      expect(c.stats.dropped, {'too_large': 1});
    });
  });

  test('feedback: its own envelope and id, linked to the report', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      String? report;
      String? note;
      c.report('r').then((v) => report = v);
      async.flushMicrotasks();
      c.feedback('the knight jumped', eventId: report).then((v) => note = v);
      c.feedback('unlinked', eventId: 'not-an-id');
      async.flushMicrotasks();
      expect(note, isNot(report));
      final env = http.sent[1].parsed;
      expect(env.header['event_id'], note);
      expect(env.items.single.type, 'feedback');
      final f = env.items.single.json;
      expect(f['event_id'], note);
      expect(f['level'], 'info');
      expect((f['contexts']! as Map)['feedback'], {
        'message': 'the knight jumped',
        'associated_event_id': report,
      });
      expect(f.containsKey('breadcrumbs'), isFalse);
      final unlinked = http.sent[2].parsed.items.single.json;
      expect((unlinked['contexts']! as Map)['feedback'], {
        'message': 'unlinked',
      });
    });
  });

  test('log lines: typed attributes, levels, base attributes', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http, tags: {'git_sha': 'abc1234'});
      c.log(
        TracerLevel.warning,
        'square',
        attributes: {
          's': 'e2',
          'i': 3,
          'd': 1.5,
          'b': true,
          'n': null,
          'list': [1, 'a'],
          'inf': double.infinity,
        },
      );
      c.log(TracerLevel.fatal, 'end');
      c.flush();
      async.flushMicrotasks();
      final env = http.sent.single.parsed;
      expect(env.header.containsKey('event_id'), isFalse);
      final item = env.items.single;
      expect(item.header, {
        'type': 'log',
        'item_count': 2,
        'content_type': 'application/vnd.sentry.items.log+json',
        'length': item.payload.length,
      });
      final entries = item.json['items']! as List;
      final first = entries.first as Map;
      expect(first['level'], 'warn');
      expect(first['severity_number'], 13);
      expect(first['body'], 'square');
      expect(first['trace_id'], c.traceId);
      expect(first['timestamp'], isA<double>());
      expect(first['attributes'], {
        'sentry.sdk.name': {'value': 'yyt.dart', 'type': 'string'},
        'sentry.sdk.version': {'value': tracerSdkVersion, 'type': 'string'},
        'sentry.release': {'value': 'playground@0.1.0+1', 'type': 'string'},
        'sentry.environment': {'value': 'debug', 'type': 'string'},
        'sentry.dist': {'value': 'abc1234', 'type': 'string'},
        'user.id': {
          'value': '00000000000000000000000000000000',
          'type': 'string',
        },
        'git_sha': {'value': 'abc1234', 'type': 'string'},
        's': {'value': 'e2', 'type': 'string'},
        'i': {'value': 3, 'type': 'integer'},
        'd': {'value': 1.5, 'type': 'double'},
        'b': {'value': true, 'type': 'boolean'},
        'list': {'value': '[1,"a"]', 'type': 'string'},
        'inf': {'value': 'Infinity', 'type': 'string'},
      });
      expect((entries.last as Map)['level'], 'fatal');
      expect((entries.last as Map)['severity_number'], 21);
    });
  });

  test('severity numbers per level', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      for (final l in TracerLevel.values) {
        c.log(l, l.name);
      }
      c.flush();
      async.flushMicrotasks();
      final entries =
          http.sent.single.parsed.items.single.json['items']! as List;
      expect(
        entries.map((e) => '${(e as Map)['level']}:${e['severity_number']}'),
        ['debug:5', 'info:9', 'warn:13', 'error:17', 'fatal:21'],
      );
    });
  });

  test('logs flush by time: not at 4999 ms, at 5000 ms', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      c.log(TracerLevel.info, 'a');
      async.elapse(const Duration(milliseconds: 4999));
      expect(http.sent, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(http.sent, hasLength(1));
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('logs flush by size: batch 3 sends on the third line', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http, logBatchSize: 3);
      c
        ..log(TracerLevel.info, '1')
        ..log(TracerLevel.info, '2');
      async.flushMicrotasks();
      expect(http.sent, isEmpty);
      c.log(TracerLevel.info, '3');
      async.flushMicrotasks();
      expect(http.sent.single.parsed.items.single.header['item_count'], 3);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a batch over 1000 lines or 1 MiB is split into containers', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http, logBatchSize: 5000);
      for (var i = 0; i < 1001; i++) {
        c.log(TracerLevel.info, '$i');
      }
      c.flush();
      async.flushMicrotasks();
      expect(http.sent.map((s) => s.parsed.items.single.header['item_count']), [
        1000,
        1,
      ]);
      http.sent.clear();
      final big = 'y' * 8000;
      for (var i = 0; i < 200; i++) {
        c.log(TracerLevel.info, big);
      }
      c.flush();
      async.flushMicrotasks();
      expect(http.sent.length, greaterThan(1));
      for (final s in http.sent) {
        expect(
          s.parsed.items.single.payload.length,
          lessThanOrEqualTo(TracerLimits.maxJsonItemBytes),
        );
      }
      final total = http.sent.fold<int>(
        0,
        (n, s) => n + (s.parsed.items.single.header['item_count']! as int),
      );
      expect(total, 200);
    });
  });

  test('a report carries the buffered log lines in its envelope', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      c
        ..trace('ui', 'tap', data: {'x': 1})
        ..log(TracerLevel.info, 'two');
      c.report('r');
      async.flushMicrotasks();
      final items = http.sent.single.parsed.items;
      expect(items.map((i) => i.type), ['event', 'log']);
      expect(items[1].header['item_count'], 2);
      final first = (items[1].json['items']! as List).first as Map;
      expect((first['attributes'] as Map)['category'], {
        'value': 'ui',
        'type': 'string',
      });
      expect((first['attributes'] as Map)['x'], {
        'value': 1,
        'type': 'integer',
      });
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('the client logs ids and statuses, never the key', () {
    fakeAsync((async) {
      final writer = CapturingLogWriter();
      final c = makeClient(
        FakeHttp(),
        logger: createFilteredLogger(
          severity: LogSeverity.debug,
          writer: writer,
        ),
      );
      c.report('r');
      async.flushMicrotasks();
      expect(writer.lines, [
        '[info] tracer active {"resource":"trc_fixture01"}',
        startsWith('[debug] tracer envelope {"kind":"event","status":200,'),
      ]);
      expect(writer.lines.join('\n'), isNot(contains(fixtureKey)));
    });
  });

  test('the client ignores lines its own logger feeds back to it', () {
    fakeAsync((async) {
      late TracerClient c;
      final http = FakeHttp();
      final logger = createFilteredLogger(
        severity: LogSeverity.debug,
        writer: LogWriters.fromFunction(
          (s, m, ctx) => c.log(TracerLevel.info, 'echo $m'),
        ),
      );
      c = makeClient(http, logger: logger);
      c.report('r');
      async.flushMicrotasks();
      c.flush();
      async.flushMicrotasks();
      expect(http.sent, hasLength(1));
    });
  });

  test('TracerLogWriter forwards lines as log and breadcrumb', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      final logger = createFilteredLogger(
        severity: LogSeverity.debug,
        writer: TracerLogWriter(client: c),
      );
      logger
        ..debug('d')
        ..info('i', {'zone': 'z1'})
        ..warn('w')
        ..error('e');
      final quiet = TracerLogWriter(client: c, breadcrumbs: false);
      quiet.info('no crumb');
      c.report('r');
      async.flushMicrotasks();
      final items = http.sent.single.parsed.items;
      final crumbs = (items[0].json['breadcrumbs']! as Map)['values'] as List;
      expect(crumbs.map((b) => '${(b as Map)['level']}:${b['message']}'), [
        'debug:d',
        'info:i',
        'warning:w',
        'error:e',
      ]);
      expect((crumbs[1] as Map)['data'], {'zone': 'z1'});
      final logs = items[1].json['items']! as List;
      expect(logs.map((l) => '${(l as Map)['level']}:${l['body']}'), [
        'debug:d',
        'info:i',
        'warn:w',
        'error:e',
        'info:no crumb',
      ]);
    });
  });

  test('Tracer.init swaps the current client and closes the previous', () {
    fakeAsync((async) {
      expect(Tracer.current.state, TracerState.off);
      final http = FakeHttp();
      final first = Tracer.init(fixtureDsn, client: http, release: 'r');
      expect(Tracer.current, same(first));
      expect(first.state, TracerState.active);
      final second = Tracer.init('');
      async.flushMicrotasks();
      expect(first.state, TracerState.closed);
      expect(second.state, TracerState.off);
      expect(http.closed, isFalse, reason: 'an injected client is the app’s');
    });
  });

  test('values that cannot be encoded never throw into the app', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      final deep = <String, Object?>{};
      var at = deep;
      for (var i = 0; i < 20; i++) {
        final next = <String, Object?>{};
        at['n'] = next;
        at = next;
      }
      c
        ..breadcrumb('x', 'y', data: {'bad': _Unprintable(), 'deep': deep})
        ..log(TracerLevel.info, 'z', attributes: {'bad': _Unprintable()});
      c.report(
        'r',
        data: {
          'set': {1, 2},
          'obj': Object(),
        },
      );
      async.flushMicrotasks();
      final e = http.sent.single.parsed.items.first.json;
      final crumb =
          ((e['breadcrumbs']! as Map)['values'] as List).single as Map;
      expect((crumb['data'] as Map)['bad'], '<unprintable>');
      expect(jsonEncode(crumb['data']), contains('"…"'));
      expect(e['extra'], {
        'set': [1, 2],
        'obj': "Instance of 'Object'",
      });
      expect(c.stats.dropped, isEmpty);
    });
  });

  test('ingest caps: 16 KiB of attributes or data, 64 tags, device.model', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = TracerClient(
        TracerOptions(
          dsn: fixtureDsn,
          client: http,
          dist: '',
          release: '',
          contexts: const {
            'device': {'model': 'pixel'},
          },
          tags: {for (var i = 0; i < 70; i++) 't$i': 'v'},
        ),
      );
      c.setTag('extra', 'x');
      c.setTag('t0', 'changed');
      final big = 'z' * 8000;
      c.log(
        TracerLevel.info,
        'wide',
        attributes: {'a': big, 'b': big, 'c': 'kept?'},
      );
      c.breadcrumb('n', 'm', data: {'a': big, 'b': big, 'c': big});
      c.report('r', data: {'a': big, 'b': big, 'c': big});
      async.flushMicrotasks();
      final items = http.sent.single.parsed.items;
      final e = items.first.json;
      expect((e['tags']! as Map).length, 64);
      expect((e['tags']! as Map)['t0'], 'changed');
      expect((e['tags']! as Map).containsKey('extra'), isFalse);
      expect(e.containsKey('dist'), isFalse, reason: 'empty is absent');
      expect(e.containsKey('release'), isFalse);
      expect(e['extra'], {'tracer.truncated': true});
      final crumb = ((e['breadcrumbs']! as Map)['values'] as List).single;
      expect((crumb as Map)['data'], {'tracer.truncated': true});
      final line = (items[1].json['items']! as List).single as Map;
      final attrs = line['attributes'] as Map;
      expect(jsonEncode(attrs).length, lessThanOrEqualTo(16 * 1024));
      expect(attrs['device.model'], {'value': 'pixel', 'type': 'string'});
      expect(attrs['tracer.truncated'], {'value': true, 'type': 'boolean'});
      expect(attrs['c'], {'value': 'kept?', 'type': 'string'});
      expect(attrs.containsKey('sentry.dist'), isFalse);
    });
  });

  test('an event that cannot fit is not sent, so no orphan attachments', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = TracerClient(
        TracerOptions(
          dsn: fixtureDsn,
          client: http,
          contexts: {
            for (var i = 0; i < 200; i++) 'c$i': {'v': 'q' * 8000},
          },
        ),
      );
      String? id = 'unset';
      c.report('r', screenshot: Uint8List(4)).then((v) => id = v);
      c.feedback('n').then((v) => id = v);
      async.flushMicrotasks();
      expect(id, isNull);
      expect(http.sent, isEmpty);
      expect(c.stats.dropped, {'too_large': 2});
    });
  });

  test('a cyclic or wide value is copied within a budget', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final c = makeClient(http);
      final cyclic = <String, Object?>{};
      for (var i = 0; i < 50; i++) {
        cyclic['k$i'] = cyclic;
      }
      c.report('r', data: {'cyclic': cyclic});
      async.flushMicrotasks();
      expect(http.sent, hasLength(1));
    });
  });

  test('TracerLogWriter without a client follows Tracer.current', () {
    fakeAsync((async) {
      final http = FakeHttp();
      final writer = TracerLogWriter(breadcrumbs: false);
      final c = Tracer.initWith(TracerOptions(dsn: fixtureDsn, client: http));
      writer.info('to current');
      c.flush();
      async.flushMicrotasks();
      expect(http.sent.single.body, isNotEmpty);
      Tracer.init('');
      async.flushMicrotasks();
    });
  });

  test('tracerSdkVersion matches the pubspec', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('\nversion: $tracerSdkVersion\n'));
  });
}
