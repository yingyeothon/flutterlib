/// A bundle's base URL, checked once at construction.
final class BundleBase {
  /// Creates a base.
  const BundleBase(this.url, this.adPrefix);

  /// Always ends in `/`.
  final String url;

  /// What precedes a file's path in its associated data: `''` for a live
  /// bundle, `'{version}/'` for a versioned one. Only known for a URL of the
  /// `/assets/{bundleId}/[{version}/]` shape; `null` otherwise.
  final String? adPrefix;
}

final RegExp _bundlePath = RegExp(r'^/assets/[^/]+/(?:([^/]+)/)?$');

/// An http(s) URL with a host and no userinfo, query or fragment. An
/// encrypted bundle's base must also have the `/assets/{bundleId}/` or
/// `/assets/{bundleId}/{version}/` shape, because the associated data every
/// file was encrypted under is derived from it. The error never quotes the
/// URL.
BundleBase parseBaseUrl(String baseUrl, {required bool encrypted}) {
  final url = Uri.tryParse(baseUrl);
  if (url == null ||
      (url.scheme != 'https' && url.scheme != 'http') ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty ||
      url.hasQuery ||
      url.hasFragment) {
    throw ArgumentError(
      'asset baseUrl must be an http(s) URL with a host and a path and '
      'nothing else',
    );
  }
  final path = url.path.endsWith('/') ? url.path : '${url.path}/';
  final match = _bundlePath.firstMatch(path);
  String? adPrefix;
  if (match != null) {
    final version = match.group(1);
    try {
      adPrefix = version == null ? '' : '${Uri.decodeComponent(version)}/';
    } on ArgumentError {
      adPrefix = null;
    } on FormatException {
      adPrefix = null;
    }
  }
  if (encrypted && adPrefix == null) {
    throw ArgumentError(
      "an encrypted bundle's baseUrl must be https://{cdn}/assets/{bundleId}/ "
      'or .../{bundleId}/{version}/',
    );
  }
  return BundleBase(url.replace(path: path).toString(), adPrefix);
}

bool _isPathUnit(int unit) =>
    unit >= 0x20 && unit != 0x7f && unit != 0x5c; // no controls, no `\`

/// A file's path below the bundle: segments separated by `/`, no leading
/// slash, no empty, `.` or `..` segment, no backslash, no control character
/// and no lone surrogate (it has no UTF-8 form). The error does not quote
/// the path.
String checkPath(String path) {
  var ok = path.isNotEmpty;
  final units = path.codeUnits;
  for (var i = 0; ok && i < units.length; i++) {
    final u = units[i];
    if (!_isPathUnit(u)) {
      ok = false;
    } else if (u >= 0xd800 && u <= 0xdbff) {
      ok =
          i + 1 < units.length &&
          units[i + 1] >= 0xdc00 &&
          units[i + 1] <= 0xdfff;
      i++;
    } else if (u >= 0xdc00 && u <= 0xdfff) {
      ok = false;
    }
  }
  if (ok) {
    ok = !path.split('/').any((s) => s.isEmpty || s == '.' || s == '..');
  }
  if (!ok) {
    throw ArgumentError(
      "asset path must be relative segments separated by '/', with no '.', "
      "'..' or empty segment",
    );
  }
  return path;
}

/// Each segment percent-encoded: `v1/데이터/노래.db` is a valid object key.
String fileUrl(BundleBase base, String path) =>
    base.url + path.split('/').map(Uri.encodeComponent).join('/');
