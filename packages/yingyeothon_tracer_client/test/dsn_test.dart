import 'package:test/test.dart';
import 'package:yingyeothon_tracer_client/yingyeothon_tracer_client.dart';

import 'fake_http_client.dart';

String refusal(String dsn, {bool allowHttpLoopback = true}) {
  try {
    TracerDsn.parse(dsn, allowHttpLoopback: allowHttpLoopback);
  } on ArgumentError catch (e) {
    return e.message as String;
  }
  return 'parsed';
}

void main() {
  test('the console DSN gives key, id and the envelope route', () {
    final dsn = TracerDsn.parse(fixtureDsn);
    expect(dsn.writeKey, fixtureKey);
    expect(dsn.resourceId, 'trc_fixture01');
    expect(
      dsn.envelopeUri.toString(),
      'https://trace.invalid/api/trc_fixture01/envelope/',
    );
    expect(dsn.toString(), 'TracerDsn(trc_fixture01)');
  });

  test('a port and a path prefix are kept', () {
    final dsn = TracerDsn.parse(
      'https://$fixtureKey@trace.invalid:8443/base/trc_a1',
    );
    expect(
      dsn.envelopeUri.toString(),
      'https://trace.invalid:8443/base/api/trc_a1/envelope/',
    );
  });

  test('http only for a loopback host, and only when allowed', () {
    for (final host in ['127.0.0.1:18096', 'localhost', '[::1]', '10.0.2.2']) {
      final dsn = TracerDsn.parse(
        'http://$fixtureKey@$host/trc_a1',
        allowHttpLoopback: true,
      );
      expect(dsn.envelopeUri.scheme, 'http');
    }
    const loop = 'http://$fixtureKey@127.0.0.1/trc_a1';
    const why =
        'tracer DSN may use http only for a loopback host in a debug build';
    expect(refusal(loop, allowHttpLoopback: false), why);
    expect(refusal('http://$fixtureKey@trace.invalid/trc_a1'), why);
    // Off unless asked for.
    expect(TracerDsn.tryParse(loop), isNull);
    expect(refusal('http://$fixtureKey@192.168.0.2/trc_a1'), why);
  });

  test('every refusal is a fixed message that never quotes the input', () {
    const marker = 'quotedmarkerquotedmarker';
    final cases = {
      'not a url $marker': 'tracer DSN must be an absolute URL',
      'ftp://$marker@trace.invalid/trc_a1': 'tracer DSN must use https',
      'https://$marker@trace.invalid/trc_a1?x=1':
          'tracer DSN must not carry a query or fragment',
      'https://$marker@trace.invalid/trc_a1#f':
          'tracer DSN must not carry a query or fragment',
      'https://trace.invalid/trc_a1':
          'tracer DSN write key is missing or malformed',
      'https://shortkey@trace.invalid/trc_a1':
          'tracer DSN write key is missing or malformed',
      'https://$marker%20x@trace.invalid/trc_a1':
          'tracer DSN write key is missing or malformed',
      'https://$marker@trace.invalid/':
          'tracer DSN must end with a trc_ resource id',
      'https://$marker@trace.invalid/7':
          'tracer DSN must end with a trc_ resource id',
      'https://$marker@trace.invalid/trc_ABC':
          'tracer DSN must end with a trc_ resource id',
    };
    for (final bad in ['%FF', ',', '"', '=']) {
      cases['https://$marker$bad@trace.invalid/trc_a1'] =
          'tracer DSN write key is missing or malformed';
    }
    cases.forEach((dsn, why) {
      expect(refusal(dsn), why, reason: why);
    });
    // The 16-character boundary: 15 refuses, 16 passes.
    expect(
      refusal('https://${'k' * 15}@trace.invalid/trc_a1'),
      'tracer DSN write key is missing or malformed',
    );
    expect(refusal('https://${'k' * 16}@trace.invalid/trc_a1'), 'parsed');
  });

  test('tryParse returns null instead of throwing', () {
    expect(TracerDsn.tryParse(''), isNull);
    expect(TracerDsn.tryParse(fixtureDsn)?.resourceId, 'trc_fixture01');
  });
}
