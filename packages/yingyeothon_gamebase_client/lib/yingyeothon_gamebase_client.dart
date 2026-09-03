/// Client SDK for the yyt realtime gateway.
///
/// Two clients over one connection state machine: [GatewayLobbyClient] for
/// a `lobby` channel (positions, chat, parties, the map) and
/// [GatewayGameClient] for a `q` channel (a dungeon run bridged to your
/// game actor). The normative wire spec is the gateway's README in the
/// `service` repository; this package follows it.
library;

export 'src/backoff.dart' show Backoff, BackoffOptions;
export 'src/client_events.dart'
    show
        DisconnectedEvent,
        GameEndedEvent,
        GatewayClientOptions,
        GatewayClientState,
        GatewayStoppedException,
        ProtocolErrorEvent,
        ReconnectingEvent,
        StoppedEvent;
export 'src/game_client.dart' show GatewayGameClient, GatewayGameClientOptions;
export 'src/gateway_url.dart' show buildGatewayUrl;
export 'src/lobby_client.dart'
    show GatewayLobbyClient, GatewayLobbyClientOptions, PartyCommands;
export 'src/protocol/capabilities.dart' show Capabilities;
export 'src/protocol/close_codes.dart'
    show
        CloseDisposition,
        CloseDispositionKind,
        GatewayChannelKind,
        GatewayCloseCode,
        classifyClose;
export 'src/protocol/frame_types.dart'
    show FrameTypes, GatewayErrorCode, SayScope, reservedGameFrameTypes;
export 'src/protocol/hello.dart' show Aoi, Hello;
export 'src/protocol/lobby_frame_writer.dart'
    show LobbyFrameWriter, isDirTooLong, maxDirBytes;
export 'src/protocol/normalize.dart' show Normalize;
export 'src/protocol/peer.dart' show Peer;
export 'src/protocol/peer_map.dart'
    show PeerChange, PeerEntered, PeerLeft, PeerMap, PeerMoved, PeerSnapshot;
export 'src/protocol/server_frames.dart'
    show
        EnterFrame,
        ErrorFrame,
        EventBroadcastFrame,
        LeaveFrame,
        LobbyServerFrame,
        PartyDeclinedFrame,
        PartyFrame,
        PartyInviteFrame,
        PartyMember,
        PongFrame,
        PosBroadcastFrame,
        SayBroadcastFrame,
        SnapshotFrame,
        UnknownServerFrame,
        readLobbyFrame;
export 'src/transport/http_fetcher.dart'
    show HttpFetchResult, HttpMapFetcher, MapFetchException, MapHttpFetcher;
export 'src/transport/web_socket.dart'
    show
        GatewayWebSocket,
        GatewayWebSocketFactory,
        GatewayWebSocketRequest,
        SocketBinaryMessage,
        SocketClosed,
        SocketEvent,
        SocketOpened,
        SocketTextMessage;
export 'src/transport/web_socket_channel_transport.dart'
    show
        WebSocketChannelFactory,
        defaultHandshakeTimeout,
        maxInboundMessageBytes;
