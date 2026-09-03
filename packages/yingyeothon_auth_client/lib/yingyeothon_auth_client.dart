/// The client's half of getting a yyt channel JWT.
///
/// One [AuthClient] per auth channel: it reads the channel's public config,
/// builds the browser sign-in URL with a nonce, parses the redirect that
/// comes back, exchanges a provider credential directly, and verifies a
/// token. Opening the browser, receiving the redirect (a deep link, a
/// loopback server, a web page) and storing the token are the app's job —
/// this package has no platform dependency.
///
/// Nothing here ever logs, throws, or returns a message that contains a
/// token, a credential, a response body or a URL with a fragment.
library;

export 'src/auth_client.dart'
    show
        AuthChannelConfig,
        AuthClient,
        AuthFailure,
        AuthFailureKind,
        ChannelToken;
