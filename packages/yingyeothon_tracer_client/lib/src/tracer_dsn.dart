/// Hosts `http` is allowed for: this machine, and the Android emulator's
/// alias for it (`adb reverse` and a local `tracer serve`).
const Set<String> _loopbackHosts = {
  '127.0.0.1',
  'localhost',
  '::1',
  '10.0.2.2',
};

final RegExp _resourceId = RegExp(r'^trc_[0-9a-z]{1,40}$');

/// A parsed tracer DSN, `https://{writeKey}@{host}/{trc_id}`, as
/// `yyt tracer dsn <res>` prints it.
///
/// [toString] never prints the write key.
final class TracerDsn {
  const TracerDsn._(this.writeKey, this.resourceId, this.envelopeUri);

  /// Parses [dsn]. Throws [ArgumentError] (whose message never quotes the
  /// input) when it is not `https://{key}@{host}[:port][/prefix]/{trc_id}`,
  /// the key is shorter than 16 characters or not printable ASCII, or the id
  /// is not the console's `trc_` shape.
  ///
  /// `http` is accepted only when [allowHttpLoopback] is true **and** the
  /// host is loopback or `10.0.2.2`, for a local `tracer serve`; off by
  /// default. `yingyeothon_tracer_flutter` turns it on in debug builds only.
  /// (`10.0.2.2` is the emulator's host alias, but an ordinary LAN address on
  /// a real device.)
  static TracerDsn parse(String dsn, {bool allowHttpLoopback = false}) {
    final Uri? uri;
    try {
      uri = Uri.tryParse(dsn.trim());
    } on Object {
      throw ArgumentError('tracer DSN must be an absolute URL');
    }
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      throw ArgumentError('tracer DSN must be an absolute URL');
    }
    final http = uri.scheme == 'http';
    if (uri.scheme != 'https' && !http) {
      throw ArgumentError('tracer DSN must use https');
    }
    if (http && !(allowHttpLoopback && _loopbackHosts.contains(uri.host))) {
      throw ArgumentError(
        'tracer DSN may use http only for a loopback host in a debug build',
      );
    }
    if (uri.hasQuery || uri.hasFragment) {
      throw ArgumentError('tracer DSN must not carry a query or fragment');
    }
    String key;
    try {
      key = Uri.decodeComponent(uri.userInfo.split(':').first);
    } on FormatException {
      key = '';
    }
    // Printable ASCII without the characters that would change the meaning
    // of the `X-Sentry-Auth` parameter list.
    if (key.length < 16 ||
        key.codeUnits.any((c) => c < 33 || c > 126) ||
        key.contains(RegExp(r'[,"=\\]'))) {
      throw ArgumentError('tracer DSN write key is missing or malformed');
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty || !_resourceId.hasMatch(segments.last)) {
      throw ArgumentError('tracer DSN must end with a trc_ resource id');
    }
    final id = segments.removeLast();
    final envelope = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      pathSegments: [...segments, 'api', id, 'envelope', ''],
    );
    return TracerDsn._(key, id, envelope);
  }

  /// [parse], or null instead of an [ArgumentError].
  static TracerDsn? tryParse(String dsn, {bool allowHttpLoopback = false}) {
    try {
      return parse(dsn, allowHttpLoopback: allowHttpLoopback);
    } on ArgumentError {
      return null;
    }
  }

  /// The resource's write key; a credential, never logged.
  final String writeKey;

  /// The resource id, `trc_…`.
  final String resourceId;

  /// `POST` target: `{base}/api/{trc_id}/envelope/`, trailing slash included.
  final Uri envelopeUri;

  @override
  String toString() => 'TracerDsn($resourceId)';
}
