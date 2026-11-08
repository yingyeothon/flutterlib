// The golden envelope of this library. Its bytes are also committed to the
// service repository as tracer/testdata/envelopes/yyt-dart/report.envelope,
// where the tracer's Go tests parse, ingest and read it back (the wire
// contract: "each library's tests decode their own output against the same
// expectations"). Regenerate with `UPDATE_GOLDEN=1 dart test
// test/golden_test.dart`, then copy the file there unchanged.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_tracer_client/yingyeothon_tracer_client.dart';

import 'fake_http_client.dart';
import 'support.dart';

/// A 1×1 transparent PNG.
final Uint8List onePixelPng = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// What the playground's "report this" sends, with fixed clock and ids.
Uint8List goldenReport() {
  late Uint8List body;
  fakeAsync((async) {
    final http = FakeHttp();
    final c = TracerClient(
      TracerOptions(
        dsn: fixtureDsn,
        release: 'playground@0.1.0+1',
        dist: 'abc1234',
        environment: 'debug',
        tags: const {'git_sha': 'abc1234', 'isolate': 'ui'},
        userId: '00000000000000000000000000000000',
        contexts: const {
          'os': {'name': 'Android', 'version': '15'},
          'device': {'model': 'fixture-device'},
        },
        client: http,
        now: steppingClock(),
        random: SequenceRandom(),
      ),
    );
    c
      ..setTag('feature', 'board')
      ..trace('navigation', 'push /board', data: {'from': '/', 'to': '/board'})
      ..trace(
        'ui',
        'tap square',
        data: {'square': 'e2', 'piece': 1, 'legal': false},
      )
      ..log(
        TracerLevel.warning,
        'move rejected',
        attributes: {'square': 'e2', 'ms': 12.5, 'attempt': 2, 'legal': false},
      );
    c.report(
      'capture report: rejected move',
      data: {'board': '8/8/8/8/8/8/4P3/8'},
      screenshot: onePixelPng,
      attachments: [
        TracerAttachment.viewHierarchy(
          utf8.encode(
            '{"rendering_system":"flutter","windows":[{"type":"MaterialApp",'
            '"depth":1,"children":[]}]}',
          ),
        ),
      ],
      error: StateError('rejected move e2'),
      stackTrace: StackTrace.fromString(
        '#0      Board.move (package:yyt_playground/board.dart:42:7)\n'
        '#1      _TracerScreenState._tap (package:yyt_playground/screens/tracer_screen.dart:88:5)\n'
        '#2      GestureRecognizer.invokeCallback (package:flutter/src/gestures/recognizer.dart:345:24)\n',
      ),
    );
    async.flushMicrotasks();
    body = http.sent.single.body;
  });
  return body;
}

void main() {
  final golden = File('test/golden/report.envelope');

  test('the report envelope is byte-for-byte the golden file', () {
    final body = goldenReport();
    if (Platform.environment['UPDATE_GOLDEN'] == '1') {
      golden.writeAsBytesSync(body);
    }
    expect(body, golden.readAsBytesSync());
  });

  // The facts tracer stores of it (normalize.Event/Logs, ingest's
  // attachment linkage); the Go side counts its rows (ingest_test.go) and
  // snapshots the read API (testdata/read/*.json).
  test('the golden decodes to what tracer stores', () {
    final env = parseEnvelope(golden.readAsBytesSync());
    expect(env.header.keys, ['event_id', 'sent_at', 'sdk']);
    expect(env.header['sdk'], {
      'name': 'yyt.dart',
      'version': tracerSdkVersion,
    });
    expect(env.items.map((i) => '${i.type}:${i.header['filename'] ?? ''}'), [
      'event:',
      'log:',
      'attachment:screenshot.png',
      'attachment:view-hierarchy.json',
    ]);
    final event = env.items[0].json;
    expect(event['event_id'], env.header['event_id']);
    expect(event['level'], 'warning');
    expect(event['release'], 'playground@0.1.0+1');
    expect(event['dist'], 'abc1234');
    expect(event['environment'], 'debug');
    expect(event['user'], {'id': '00000000000000000000000000000000'});
    expect(event['tags'], {
      'git_sha': 'abc1234',
      'isolate': 'ui',
      'feature': 'board',
    });
    final contexts = event['contexts']! as Map;
    expect(contexts['os'], {'name': 'Android', 'version': '15'});
    expect(contexts['device'], {'model': 'fixture-device'});
    final exception =
        ((event['exception']! as Map)['values'] as List).single as Map;
    expect(exception['type'], 'StateError');
    final frames = (exception['stacktrace']! as Map)['frames'] as List;
    expect(frames.map((f) => (f as Map)['in_app']), [false, true, true]);
    expect((event['breadcrumbs']! as Map)['values'], hasLength(2));
    final logs = env.items[1];
    expect(logs.header['item_count'], 3);
    final entries = logs.json['items']! as List;
    expect(entries.map((e) => (e as Map)['body']), [
      'push /board',
      'tap square',
      'move rejected',
    ]);
    final attrs = (entries.last as Map)['attributes'] as Map;
    expect(attrs['square'], {'value': 'e2', 'type': 'string'});
    expect(attrs['ms'], {'value': 12.5, 'type': 'double'});
    expect(attrs['attempt'], {'value': 2, 'type': 'integer'});
    expect(attrs['legal'], {'value': false, 'type': 'boolean'});
    expect(attrs['sentry.release'], {
      'value': 'playground@0.1.0+1',
      'type': 'string',
    });
    expect(env.items[2].payload, onePixelPng);
    expect(env.items[2].header['content_type'], 'image/png');
    expect(env.items[3].header['attachment_type'], 'event.view_hierarchy');
  });
}
