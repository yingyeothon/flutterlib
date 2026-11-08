import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// The fixture DSN of the service's golden envelopes
/// (`tracer/testdata/envelopes/README.md`, _Fixture values_). Not a real key.
const String fixtureKey = 'fixturewritekeyfixturewritekey00';

/// [fixtureKey] at the fixture resource on a host that never resolves.
const String fixtureDsn = 'https://$fixtureKey@trace.invalid/trc_fixture01';

/// One request the client made, with the body decompressed.
final class SentEnvelope {
  SentEnvelope(this.request, this.body);
  final http.Request request;

  /// The envelope bytes as encoded, before gzip.
  final Uint8List body;

  /// Header line, then per item its header and payload.
  late final ({Map<String, Object?> header, List<WireItemView> items}) parsed =
      parseEnvelope(body);
}

/// An item as the ingest's `envelope.Reader` sees it.
final class WireItemView {
  WireItemView(this.header, this.payload);
  final Map<String, Object?> header;
  final Uint8List payload;
  String get type => header['type']! as String;
  Map<String, Object?> get json =>
      jsonDecode(utf8.decode(payload)) as Map<String, Object?>;
}

/// Parses an envelope the way `tracer/internal/envelope` does: a header
/// line, then items with an explicit `length` and a trailing newline.
({Map<String, Object?> header, List<WireItemView> items}) parseEnvelope(
  Uint8List body,
) {
  var at = body.indexOf(0x0A);
  final header =
      jsonDecode(utf8.decode(body.sublist(0, at))) as Map<String, Object?>;
  at++;
  final items = <WireItemView>[];
  while (at < body.length) {
    final end = body.indexOf(0x0A, at);
    final ih =
        jsonDecode(utf8.decode(body.sublist(at, end))) as Map<String, Object?>;
    final length = ih['length']! as int;
    final start = end + 1;
    items.add(WireItemView(ih, body.sublist(start, start + length)));
    if (body[start + length] != 0x0A) throw StateError('no newline');
    at = start + length + 1;
  }
  return (header: header, items: items);
}

/// A scripted HTTP client: each request is recorded, each answer comes from
/// a queue (a status with headers, or an error to throw). With an empty
/// queue it answers `200 {"id":""}`.
final class FakeHttp extends http.BaseClient {
  final List<SentEnvelope> sent = [];
  final List<Object> _answers = [];
  bool closed = false;

  void answer(int status, [Map<String, String> headers = const {}]) =>
      _answers.add((status, headers));

  void fail(Object error) => _answers.add(error);

  /// A `send` that never completes until its abort trigger fires.
  void stall() => _answers.add(#stall);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final r = request as http.Request;
    final raw = r.bodyBytes;
    final body = r.headers['content-encoding'] == 'gzip'
        ? Uint8List.fromList(gzip.decode(raw))
        : raw;
    sent.add(SentEnvelope(r, body));
    final next = _answers.isEmpty
        ? (200, const <String, String>{})
        : _answers.removeAt(0);
    if (next == #stall) {
      final done = Completer<http.StreamedResponse>();
      if (r is http.AbortableRequest) {
        unawaited(
          r.abortTrigger?.then(
            (_) => done.completeError(http.RequestAbortedException(r.url)),
          ),
        );
      }
      return done.future;
    }
    if (next is (int, Map<String, String>)) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"id":""}')),
        next.$1,
        headers: next.$2,
      );
    }
    throw next;
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}
