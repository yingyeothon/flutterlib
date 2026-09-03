@Tags(['integration'])
// The server-side sockets belong to the scripted server, which closes them.
// ignore_for_file: close_sinks
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

/// A scripted `dart:io` WebSocket server: the test decides, per upgrade,
/// whether to accept, which subprotocol to echo, and what to do next.
final class ScriptedServer {
  ScriptedServer._(this._server);

  static Future<ScriptedServer> start() async =>
      ScriptedServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final StreamController<WebSocket> _sockets =
      StreamController<WebSocket>.broadcast();

  Uri get url => Uri.parse('ws://127.0.0.1:${_server.port}');

  Stream<WebSocket> get sockets => _sockets.stream;

  /// Accepts every upgrade, echoing [protocol] (or none).
  void accept({String? protocol = 'bearer'}) {
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: protocol == null ? null : (_) => protocol,
      );
      _sockets.add(socket);
    });
  }

  /// Refuses every upgrade with [status].
  void refuse(int status) {
    _server.listen((request) async {
      request.response.statusCode = status;
      await request.response.close();
    });
  }

  /// Accepts the TCP connection but never answers the handshake.
  void hang() {
    _server.listen((request) {});
  }

  Future<void> close() => _server.close(force: true);

  /// Reads [ws] to completion and returns its close code. A `dart:io`
  /// server socket answers a close frame only while it is being read, and
  /// its `done` future does not complete after a client-initiated close —
  /// the stream's end is the signal.
  static Future<int?> closedCode(WebSocket ws) async {
    await ws.drain<void>();
    return ws.closeCode;
  }
}

Future<List<SocketEvent>> collect(
  GatewayWebSocket socket, {
  int until = 1,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final events = <SocketEvent>[];
  final done = Completer<void>();
  socket.events.listen(
    (e) {
      events.add(e);
      if (e is SocketClosed && !done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future.timeout(timeout);
  return events;
}

const factory = WebSocketChannelFactory(handshakeTimeout: Duration(seconds: 2));

GatewayWebSocketRequest request(
  Uri url, [
  String token = 'eyJ.secret-token.sig',
]) => GatewayWebSocketRequest(
  url: url.replace(queryParameters: {'channel': 'c'}),
  subprotocols: ['bearer', token],
);

void main() {
  late ScriptedServer server;
  setUp(() async => server = await ScriptedServer.start());
  tearDown(() => server.close());

  test(
    'negotiates bearer and reports the server close code and reason',
    () async {
      server.accept();
      final serverSide = server.sockets.first;
      final socket = factory.connect(request(server.url));
      final eventsFuture = collect(socket);
      final ws = await serverSide;
      ws.add('{"type":"hello"}');
      await ws.close(4002, 'idle');
      final events = await eventsFuture;
      expect(events[0], isA<SocketOpened>());
      expect((events[0] as SocketOpened).protocol, 'bearer');
      expect(events[1], isA<SocketTextMessage>());
      expect((events[1] as SocketTextMessage).text, '{"type":"hello"}');
      expect(events[2], isA<SocketClosed>());
      expect((events[2] as SocketClosed).code, 4002);
      expect((events[2] as SocketClosed).reason, 'idle');
      expect(events, hasLength(3));
    },
  );

  test('a server that echoes no subprotocol reports protocol null', () async {
    server.accept(protocol: null);
    final serverSide = server.sockets.first;
    final socket = factory.connect(request(server.url));
    final ws = await serverSide;
    final eventsFuture = collect(socket);
    await ws.close(1000);
    final events = await eventsFuture;
    expect((events.first as SocketOpened).protocol, isNull);
  });

  test('a refused handshake is a 1006 close, not a stream error', () async {
    server.refuse(401);
    final events = await collect(factory.connect(request(server.url)));
    expect(events, hasLength(1));
    expect((events.single as SocketClosed).code, 1006);
  });

  test('a hung handshake times out to 1006', () async {
    server.hang();
    final events = await collect(factory.connect(request(server.url)));
    expect((events.single as SocketClosed).code, 1006);
  });

  test('a binary frame is reported as such', () async {
    server.accept();
    final serverSide = server.sockets.first;
    final socket = factory.connect(request(server.url));
    final ws = await serverSide;
    final eventsFuture = collect(socket);
    ws.add([1, 2, 3]);
    await ws.close(1000);
    final events = await eventsFuture;
    expect(events[1], isA<SocketBinaryMessage>());
  });

  test(
    'a local close is reported with the code the client asked for',
    () async {
      server.accept();
      final serverSide = server.sockets.first;
      final socket = factory.connect(request(server.url));
      final ws = await serverSide;
      final serverClose = ScriptedServer.closedCode(ws);
      final events = <SocketEvent>[];
      final closed = Completer<void>();
      socket.events.listen((e) {
        events.add(e);
        if (e is SocketOpened) socket.close(4900, 'hello timeout');
        if (e is SocketClosed) closed.complete();
      });
      await closed.future.timeout(const Duration(seconds: 5));
      expect((events.last as SocketClosed).code, 4900);
      expect(
        await serverClose.timeout(const Duration(seconds: 5)),
        4900,
        reason: 'the server saw the closing handshake',
      );
    },
  );

  test('a close during the handshake is reported with that code', () async {
    server.accept();
    final serverSide = server.sockets.first;
    final socket = factory.connect(request(server.url));
    socket.close(4900, 'gave up');
    final events = await collect(socket);
    expect(events, hasLength(1));
    expect((events.single as SocketClosed).code, 4900);
    final ws = await serverSide;
    expect(
      await ScriptedServer.closedCode(ws).timeout(const Duration(seconds: 5)),
      4900,
    );
  });

  test('send reaches the server', () async {
    server.accept();
    final serverSide = server.sockets.first;
    final socket = factory.connect(request(server.url));
    final ws = await serverSide;
    final received = ws.first;
    await socket.events.firstWhere((e) => e is SocketOpened);
    socket.send('{"type":"ping"}');
    expect(await received, '{"type":"ping"}');
    socket.close(1000, '');
  });

  test('64 KiB passes and 64 KiB + 1 closes with 4900', () async {
    server.accept();
    final first = server.sockets.first;
    final okSocket = factory.connect(request(server.url));
    final ws1 = await first;
    final okEvents = collect(okSocket);
    ws1.add('x' * maxInboundMessageBytes);
    await ws1.close(1000);
    expect((await okEvents)[1], isA<SocketTextMessage>());

    final second = server.sockets.first;
    final bigSocket = factory.connect(request(server.url));
    final ws2 = await second;
    final serverClose = ScriptedServer.closedCode(ws2);
    final bigEvents = collect(bigSocket);
    ws2.add('한' * (maxInboundMessageBytes ~/ 3 + 1)); // 3 bytes each: over
    final events = await bigEvents;
    expect(events.whereType<SocketTextMessage>(), isEmpty);
    expect((events.last as SocketClosed).code, 4900);
    expect(await serverClose.timeout(const Duration(seconds: 5)), 4900);
  });

  test(
    'a malformed subprotocol is refused before connecting, by index only',
    () async {
      const bad = 'eyJ.secret\ntoken.sig';
      expect(
        () => factory.connect(request(server.url, bad)),
        throwsA(
          predicate(
            (Object e) =>
                e is ArgumentError &&
                e.message ==
                    'subprotocol 1 has an illegal character at index 10' &&
                !e.toString().contains('secret'),
          ),
        ),
      );
      expect(
        () => factory.connect(request(server.url, '')),
        throwsArgumentError,
      );
    },
  );

  test('a non-ws URL is refused before connecting', () {
    expect(
      () => factory.connect(
        GatewayWebSocketRequest(
          url: Uri.parse('https://gw.example'),
          subprotocols: ['bearer', 't'],
        ),
      ),
      throwsArgumentError,
    );
  });

  test('a close code a client may not send is refused', () async {
    server.accept();
    final socket = factory.connect(request(server.url));
    await socket.events.firstWhere((e) => e is SocketOpened);
    expect(() => socket.close(1001, ''), throwsArgumentError);
    expect(() => socket.close(2999, ''), throwsArgumentError);
    socket.close(1000, '');
  });
}
