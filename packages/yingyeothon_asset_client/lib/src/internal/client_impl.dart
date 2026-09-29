import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../asset_bundle_client.dart';
import '../errors.dart';
import '../types.dart';
import 'crypto.dart';
import 'format.dart';
import 'http.dart';
import 'key.dart';
import 'paths.dart';

/// How often a read starts over because the object changed under it.
const int _maxRestarts = 3;

/// The message of the one ArgumentError raised after requests: a resume
/// offset past the end of a file whose length has just been authenticated.
const String resumePastEnd = 'asset resume offset is past the end of the file';

/// The zone key of an encrypted attempt's decryptor collector.
final Object _createdKey = Object();

/// An attempt saw the object change; [_restarting] starts over.
final class _Changed implements Exception {
  const _Changed(this.status);
  final int status;
}

AssetClientException _httpError(int status, [String? detail]) =>
    AssetClientException(
      AssetClientErrorCode.http,
      status: status,
      detail: detail,
    );

/// The request was refused before any answer — what a browser does to a
/// preflighted request — as opposed to a timeout or a body that failed.
bool _isRejection(Object error) =>
    error is AssetClientException &&
    error.code == AssetClientErrorCode.network &&
    error.status == 0 &&
    error.detail == null;

int _checkOffset(int value, String name) {
  if (value < 0) {
    throw ArgumentError('asset $name must not be negative');
  }
  return value;
}

final class _File {
  const _File(this.path, this.url, this.ad);
  final String path;
  final String url;

  /// The associated data: the object key below the bundle.
  final String ad;
}

/// Which segments a window needs, once the length is known.
final class _Plan {
  const _Plan(this.start, this.end, this.first, this.last);
  final int start;
  final int end;
  final int first;
  final int last;
}

/// One encrypted read, opened: the body is positioned at segment `first`.
final class _Opened {
  const _Opened(this.decryptor, this.etag, this.plan, this.body);
  final Decryptor decryptor;
  final String? etag;
  final _Plan plan;
  final BodyReader body;
}

/// The client behind [AssetBundleClient].
final class AssetBundleClientImpl implements AssetBundleClient {
  /// Validates the options and copies the key.
  AssetBundleClientImpl(AssetBundleClientOptions options)
    : _logger = options.logger ?? nullLogger,
      _corsSafe = options.effectiveCorsSafe,
      _base = parseBaseUrl(options.baseUrl, encrypted: options.key != null),
      _crypto = options.key == null
          ? null
          : BundleCrypto(parseAssetKey(options.key!)),
      _http = options.client ?? http.Client(),
      _ownsHttp = options.client == null {
    _requester = Requester(
      _http,
      _logger,
      options.responseTimeout,
      options.bodyIdleTimeout,
      () => _closed,
    );
  }

  final Logger _logger;
  final bool _corsSafe;
  final BundleBase _base;
  final BundleCrypto? _crypto;
  final http.Client _http;
  final bool _ownsHttp;
  late final Requester _requester;
  bool _closed = false;

  bool get _encrypted => _crypto != null;

  _File _fileOf(String path) {
    if (_closed) throw StateError('asset client is closed');
    final checked = checkPath(path);
    return _File(
      checked,
      fileUrl(_base, checked),
      (_base.adPrefix ?? '') + checked,
    );
  }

  /// Opens a decryptor and records it in the zone's collector, when an
  /// attempt of [_openEncrypted] runs one.
  Decryptor _openDecryptor(Uint8List header, int total, String ad) {
    final decryptor = _bundleCrypto().openDecryptor(header, total, ad);
    final created = Zone.current[_createdKey];
    if (created is List<Decryptor>) created.add(decryptor);
    return decryptor;
  }

  BundleCrypto _bundleCrypto() {
    final crypto = _crypto;
    if (crypto == null || _closed) throw StateError('asset client is closed');
    return crypto;
  }

  Future<T> _restarting<T>(
    _File file,
    Future<T> Function() attempt,
    FutureOr<void> Function() onChanged,
  ) async {
    for (var restart = 0; ; restart++) {
      try {
        return await attempt();
      } on _Changed catch (changed) {
        // Never reset a sink for a client closed meanwhile.
        if (_closed) throw StateError('asset client is closed');
        if (restart >= _maxRestarts) {
          throw _httpError(changed.status, 'the object kept changing');
        }
        _logger.info('asset changed during a read; starting over', {
          'path': loggablePath(file.path),
          'restart': restart + 1,
        });
        await onChanged();
      }
    }
  }

  /// Accepts a ranged answer, or says why not. A `200` to a request that
  /// carried `If-Range`, another ETag or another total length means the
  /// object changed (start over); a `200` otherwise means the host ignores
  /// `Range`.
  ({int? total, String? etag}) _checkRanged(
    Answer answer, {
    required int from,
    required int? to,
    required int? total,
    required String? etag,
    required bool ifRangeSent,
    required bool corsSafe,
  }) {
    final status = answer.status;
    if (status == 200) {
      if (ifRangeSent) throw _Changed(status);
      if (etag != null && answer.etag != etag) throw _Changed(status);
      throw _httpError(status, 'the host ignores Range');
    }
    if (status == 416) {
      // The range was computed from a length the object no longer has; with
      // nothing known yet, the object is empty, which no ciphertext is.
      if (total != null) throw _Changed(status);
      throw corrupt(status);
    }
    // Without `If-Range`, only the answer's own ETag says which object this
    // is; an answer that names none cannot be spliced onto one that did.
    if (etag != null &&
        answer.etag != etag &&
        (answer.etag != null || !ifRangeSent)) {
      throw _Changed(status);
    }
    final range = answer.range;
    if (range == null) {
      if (!corsSafe) throw _httpError(status, 'no Content-Range');
      return (total: total, etag: answer.etag ?? etag);
    }
    final rangeTotal = range.total;
    if (rangeTotal == null) {
      throw _httpError(status, 'no total length in Content-Range');
    }
    if (total != null && rangeTotal != total) throw _Changed(status);
    final wantEnd = to == null || to > rangeTotal - 1 ? rangeTotal - 1 : to;
    if (range.start != from || range.end != wantEnd) {
      throw _httpError(status, 'Content-Range is not the range asked for');
    }
    return (total: rangeTotal, etag: answer.etag ?? etag);
  }

  _Plan _planWindow(int total, int start, int? end) {
    final segments = segmentsOf(total);
    if (segments == null) throw corrupt();
    final plainLength = plaintextLengthOf(total, segments);
    final s = start < plainLength ? start : plainLength;
    final e = end == null || end > plainLength ? plainLength : end;
    // The length came from an unauthenticated header, so a window with
    // nothing in it — an empty file, a window past the end, a finished
    // resume — still fetches and verifies the last segment: its `last` flag
    // and its exact extent prove the length, the key and the path. Nothing
    // of it is released.
    final empty = s >= e;
    return _Plan(
      s,
      e,
      empty ? segments - 1 : segmentOf(s),
      empty ? segments - 1 : segmentOf(e - 1),
    );
  }

  /// Opens plaintext `[start, end)` of an encrypted file. Every body this
  /// opened and did not hand back is cancelled, on success and on failure,
  /// so a refused answer never holds its connection.
  Future<_Opened> _openEncrypted(
    _File file,
    int start,
    int? end,
    String? resumeEtag,
    bool noCache,
  ) async {
    final bodies = <BodyReader>[];
    Future<Answer> send(RequestSpec spec) async {
      final answer = await _requester.send(
        file.url,
        file.path,
        RequestSpec(
          spec.method,
          spec.kind,
          from: spec.from,
          to: spec.to,
          ifRange: spec.ifRange,
          noCache: noCache && !_corsSafe,
        ),
      );
      bodies.add(answer.body);
      return answer;
    }

    // Only this attempt's decryptors: another read on the same client may
    // have its own open.
    final created = <Decryptor>[];
    _Opened? kept;
    try {
      final opened = await runZoned(
        () => _openWith(send, file, start, end, resumeEtag),
        zoneValues: {_createdKey: created},
      );
      kept = opened;
      return opened;
    } finally {
      for (final body in bodies) {
        if (!identical(body, kept?.body)) await body.cancel();
      }
      // A decryptor opened for an attempt that did not hand it back holds
      // derived keys nobody would zero.
      for (final d in created) {
        if (!identical(d, kept?.decryptor)) d.close();
      }
    }
  }

  Future<_Opened> _openWith(
    Future<Answer> Function(RequestSpec) send,
    _File file,
    int start,
    int? end,
    String? resumeEtag,
  ) async {
    if (!_corsSafe) {
      return _openConditional(send, file, start, end, resumeEtag);
    }
    // `Content-Range` is unreadable and `If-Range` would need a preflight
    // the CDN refuses, so the length and the identity come from a HEAD.
    final head = await send(const RequestSpec('HEAD', RequestKind.head));
    if (head.status != 200) throw _httpError(head.status);
    final total = head.length;
    if (head.encoded || total == null) {
      throw _httpError(head.status, 'no usable Content-Length');
    }
    if (resumeEtag != null && head.etag != resumeEtag) {
      throw _Changed(head.status);
    }
    try {
      return await _openSafelisted(send, file, start, end, total, head.etag);
    } on AssetClientException catch (error) {
      if (!_isRejection(error)) rethrow;
      // The HEAD went through and a request that differs from it only by
      // `Range` did not: a browser that still preflights `Range`, which the
      // CDN refuses. The whole file still verifies segment by segment.
      _logger.warn('asset ranged request refused; reading the whole file', {
        'path': loggablePath(file.path),
      });
      return _openWhole(send, file, start, end, total, head.etag);
    }
  }

  /// Outside a browser: `Content-Range` for the length, `If-Range` for the
  /// identity.
  Future<_Opened> _openConditional(
    Future<Answer> Function(RequestSpec) send,
    _File file,
    int start,
    int? end,
    String? resumeEtag,
  ) async {
    final first = segmentOf(start);
    final ifRange = isStrongEtag(resumeEtag) ? resumeEtag : null;
    // The header and the first segments arrive in one request when the
    // window starts in segment 0; the host clamps a range past the end.
    final int? to = first != 0
        ? headerLength - 1
        : end == null
        ? null
        : segmentExtent(segmentOf(end - 1 < 0 ? 0 : end - 1)).end - 1;
    final answer = await send(
      RequestSpec(
        'GET',
        first == 0 ? RequestKind.segments : RequestKind.header,
        from: 0,
        to: to,
        ifRange: ifRange,
      ),
    );
    final checked = _checkRanged(
      answer,
      from: 0,
      to: to,
      total: null,
      etag: resumeEtag,
      ifRangeSent: ifRange != null,
      corsSafe: false,
    );
    final total = checked.total;
    if (total == null) throw _httpError(answer.status, 'no total length');
    final header = await answer.body.readExactly(
      total < headerLength ? total : headerLength,
    );
    final plan = _planWindow(total, start, end);
    final decryptor = _openDecryptor(header, total, file.ad);
    if (first == 0 && plan.first == 0) {
      return _Opened(decryptor, checked.etag, plan, answer.body);
    }
    return _openSegments(send, decryptor, plan, total, checked.etag);
  }

  /// In a browser: only `Range` crosses, and each answer's ETag is compared.
  Future<_Opened> _openSafelisted(
    Future<Answer> Function(RequestSpec) send,
    _File file,
    int start,
    int? end,
    int total,
    String? etag,
  ) async {
    final plan = _planWindow(total, start, end);
    final to = plan.first == 0
        ? segmentExtent(plan.last, total).end - 1
        : headerLength - 1;
    final answer = await send(
      RequestSpec(
        'GET',
        plan.first == 0 ? RequestKind.segments : RequestKind.header,
        from: 0,
        to: to,
      ),
    );
    _checkRanged(
      answer,
      from: 0,
      to: to,
      total: total,
      etag: etag,
      ifRangeSent: false,
      corsSafe: true,
    );
    final header = await answer.body.readExactly(
      total < headerLength ? total : headerLength,
    );
    final decryptor = _openDecryptor(header, total, file.ad);
    if (plan.first == 0) return _Opened(decryptor, etag, plan, answer.body);
    return _openSegments(send, decryptor, plan, total, etag);
  }

  /// The ranged request for segments `first … last`, after the header.
  Future<_Opened> _openSegments(
    Future<Answer> Function(RequestSpec) send,
    Decryptor decryptor,
    _Plan plan,
    int total,
    String? etag,
  ) async {
    final from = segmentExtent(plan.first, total).start;
    final to = segmentExtent(plan.last, total).end - 1;
    final ifRange = !_corsSafe && isStrongEtag(etag) ? etag : null;
    final answer = await send(
      RequestSpec(
        'GET',
        RequestKind.segments,
        from: from,
        to: to,
        ifRange: ifRange,
      ),
    );
    _checkRanged(
      answer,
      from: from,
      to: to,
      total: total,
      etag: etag,
      ifRangeSent: ifRange != null,
      corsSafe: _corsSafe,
    );
    return _Opened(decryptor, etag, plan, answer.body);
  }

  /// The fallback when `Range` cannot be sent: one plain GET, the segments
  /// before the window read and dropped unreleased, then the window verified
  /// as usual.
  Future<_Opened> _openWhole(
    Future<Answer> Function(RequestSpec) send,
    _File file,
    int start,
    int? end,
    int total,
    String? etag,
  ) async {
    final answer = await send(const RequestSpec('GET', RequestKind.whole));
    if (answer.status != 200) throw _httpError(answer.status);
    if (etag != null && answer.etag != etag) throw _Changed(answer.status);
    final plan = _planWindow(total, start, end);
    final header = await answer.body.readExactly(
      total < headerLength ? total : headerLength,
    );
    final decryptor = _openDecryptor(header, total, file.ad);
    final target = segmentExtent(plan.first, total).start;
    for (var at = headerLength; at < target;) {
      final step = target - at < segmentSize ? target - at : segmentSize;
      await answer.body.readExactly(step);
      at += step;
    }
    return _Opened(decryptor, etag, plan, answer.body);
  }

  /// Verifies and emits the opened window segment by segment: one segment in
  /// memory at a time, and no byte of it before its tag verified.
  Future<void> _emitSegments(
    _Opened opened,
    Future<void> Function(Uint8List chunk) emit,
  ) async {
    final decryptor = opened.decryptor;
    try {
      for (var i = opened.plan.first; i <= opened.plan.last; i++) {
        final extent = segmentExtent(i, decryptor.total);
        final plain = decryptor.open(
          i,
          await opened.body.readExactly(extent.end - extent.start),
        );
        final at = plainStart(i);
        final lo = opened.plan.start - at > 0 ? opened.plan.start - at : 0;
        final hi = opened.plan.end - at < plain.length
            ? opened.plan.end - at
            : plain.length;
        if (lo < hi) await emit(Uint8List.sublistView(plain, lo, hi));
      }
    } finally {
      decryptor.close();
      await opened.body.cancel();
    }
  }

  Future<Uint8List> _readEncryptedRange(
    _File file,
    int start,
    int? end,
    bool noCache,
  ) {
    // Copied as it is added: a chunk is a view of a whole decrypted segment,
    // and nothing outside the window may leave through the result's buffer.
    var chunks = BytesBuilder();
    return _restarting(file, () async {
      final opened = await _openEncrypted(file, start, end, null, noCache);
      await _emitSegments(opened, (chunk) async => chunks.add(chunk));
      return chunks.toBytes();
    }, () => chunks = BytesBuilder());
  }

  Future<Uint8List> _readWhole(_File file, bool noCache) async {
    final answer = await _requester.send(
      file.url,
      file.path,
      RequestSpec('GET', RequestKind.whole, noCache: noCache && !_corsSafe),
    );
    try {
      if (answer.status != 200) throw _httpError(answer.status);
      if (!_encrypted) return await answer.body.rest(maxCiphertext);
      // Refuse a length no ciphertext has before holding any of it, and stop
      // reading an unsized body once it has passed the largest one.
      final declared = answer.length;
      if (!answer.encoded && declared != null && segmentsOf(declared) == null) {
        throw corrupt(answer.status);
      }
      final builder = BytesBuilder(copy: false);
      for (
        var chunk = await answer.body.next();
        chunk != null;
        chunk = await answer.body.next()
      ) {
        builder.add(chunk);
        if (builder.length > maxCiphertext) throw corrupt(answer.status);
      }
      final ciphertext = builder.takeBytes();
      final total = ciphertext.length;
      final decryptor = _bundleCrypto().openDecryptor(
        Uint8List.sublistView(
          ciphertext,
          0,
          total < headerLength ? total : headerLength,
        ),
        total,
        file.ad,
      );
      try {
        final out = Uint8List(decryptor.plaintextLength);
        for (var i = 0; i < decryptor.segments; i++) {
          final extent = segmentExtent(i, total);
          out.setAll(
            plainStart(i),
            decryptor.open(
              i,
              Uint8List.sublistView(ciphertext, extent.start, extent.end),
            ),
          );
        }
        return out;
      } finally {
        decryptor.close();
      }
    } finally {
      await answer.body.cancel();
    }
  }

  Future<Uint8List> _readPlainRange(
    _File file,
    int start,
    int? end,
    bool noCache,
  ) async {
    final to = end == null ? null : end - 1;
    Answer answer;
    try {
      answer = await _requester.send(
        file.url,
        file.path,
        RequestSpec(
          'GET',
          RequestKind.range,
          from: start,
          to: to,
          noCache: noCache && !_corsSafe,
        ),
      );
    } on AssetClientException catch (error) {
      if (!_corsSafe || !_isRejection(error)) rethrow;
      _logger.warn('asset ranged request refused; reading the whole file', {
        'path': loggablePath(file.path),
      });
      answer = await _requester.send(
        file.url,
        file.path,
        const RequestSpec('GET', RequestKind.whole),
      );
    }
    try {
      if (answer.status == 416) {
        if (_closed) throw StateError('asset client is closed');
        return Uint8List(0);
      }
      if (answer.status == 200) {
        // `Range` was ignored or never sent: this is the whole file.
        final all = await answer.body.rest(maxCiphertext);
        final s = start < all.length ? start : all.length;
        final e = end == null || end > all.length ? all.length : end;
        return Uint8List.fromList(Uint8List.sublistView(all, s, e < s ? s : e));
      }
      final range = answer.range;
      if (range == null && !_corsSafe) {
        throw _httpError(answer.status, 'no Content-Range');
      }
      if (range != null) {
        final rangeTotal = range.total;
        final wantEnd = rangeTotal == null
            ? null
            : (to == null || to > rangeTotal - 1 ? rangeTotal - 1 : to);
        if (range.start != start || (wantEnd != null && range.end != wantEnd)) {
          throw _httpError(
            answer.status,
            'Content-Range is not the range asked for',
          );
        }
      }
      final expected = range == null ? null : range.end - range.start + 1;
      // A stated range is the host's word: no larger than any asset either.
      if (expected != null && expected > maxCiphertext) {
        await answer.body.cancel();
        throw tooLarge(answer.status);
      }
      final bytes = expected == null
          ? await answer.body.rest(maxCiphertext)
          : await answer.body.rest(
              expected,
              (status) =>
                  networkError(status, 'the body ran past its stated length'),
            );
      if (expected != null && bytes.length < expected) {
        throw networkError(answer.status, 'the body ended early');
      }
      var take = bytes.length;
      if (expected != null && expected < take) take = expected;
      if (end != null && end - start < take) take = end - start;
      return Uint8List.fromList(Uint8List.sublistView(bytes, 0, take));
    } finally {
      await answer.body.cancel();
    }
  }

  Future<AssetDownloadResult> _downloadEncrypted(
    _File file,
    AssetSink sink,
    void Function(AssetDownloadProgress)? onProgress,
    int offset,
    String? resumeEtag,
    bool noCache,
  ) {
    var written = offset;
    var etagToMatch = resumeEtag;
    return _restarting(
      file,
      () async {
        final opened = await _openEncrypted(
          file,
          written,
          null,
          etagToMatch,
          noCache,
        );
        final total = opened.decryptor.plaintextLength;
        final overshot = written > total;
        var reported = false;
        void report() {
          reported = true;
          onProgress?.call(
            AssetDownloadProgress(
              written: written,
              total: total,
              etag: opened.etag,
            ),
          );
        }

        await _emitSegments(opened, (chunk) async {
          await sink.write(chunk);
          written += chunk.length;
          report();
        });
        // Only now is the length authenticated (the last segment verified),
        // so only now can an offset past it be the caller's mistake.
        if (overshot) {
          throw ArgumentError(resumePastEnd);
        }
        // An empty file, or a resume that was already complete: nothing was
        // written, and the caller still hears that the download is whole.
        if (!reported) report();
        return AssetDownloadResult(bytes: total, etag: opened.etag);
      },
      () async {
        if (written > 0) await sink.reset();
        written = 0;
        etagToMatch = null;
      },
    );
  }

  Future<AssetDownloadResult> _downloadPlain(
    _File file,
    AssetSink sink,
    void Function(AssetDownloadProgress)? onProgress,
    int offset,
    String? resumeEtag,
    bool noCache,
  ) {
    var written = offset;
    var etagToMatch = resumeEtag;
    final cacheFlag = noCache && !_corsSafe;
    Future<Answer> whole() => _requester.send(
      file.url,
      file.path,
      RequestSpec('GET', RequestKind.whole, noCache: cacheFlag),
    );

    Future<AssetDownloadResult> consume(Answer answer, bool ifRangeSent) async {
      int? total;
      if (answer.status == 416) {
        // Nothing at or after the offset. Under a matching `If-Range` whose
        // stated length is the offset, the earlier download was complete;
        // anything else is another object, read afresh.
        if (_closed) throw StateError('asset client is closed');
        if (ifRangeSent && answer.unsatisfiedTotal == written) {
          onProgress?.call(
            AssetDownloadProgress(
              written: written,
              total: written,
              etag: etagToMatch,
            ),
          );
          return AssetDownloadResult(bytes: written, etag: etagToMatch);
        }
        throw _Changed(answer.status);
      }
      if (answer.status == 206) {
        // Without `If-Range` only the answer's own ETag names the object.
        if (answer.etag != etagToMatch &&
            (answer.etag != null || !ifRangeSent)) {
          throw _Changed(answer.status);
        }
        final range = answer.range;
        if (range == null && !_corsSafe) {
          throw _httpError(answer.status, 'no Content-Range');
        }
        if (range != null && range.start != written) {
          throw _httpError(
            answer.status,
            'Content-Range is not the range asked for',
          );
        }
        final length = answer.length;
        total =
            range?.total ??
            // A browser hides `Content-Encoding`, so there a length may be
            // the compressed size.
            (length == null || answer.encoded || _corsSafe
                ? null
                : written + length);
      } else {
        // A 200 is the whole file: under `If-Range` the object changed, and
        // without it the host ignored `Range`.
        if (written > 0) await sink.reset();
        written = 0;
        // A browser cannot see `Content-Encoding` cross-origin, so there a
        // `Content-Length` may be the compressed size: no total at all.
        total = answer.encoded || _corsSafe ? null : answer.length;
      }
      final etag = answer.etag ?? etagToMatch;
      var reported = false;
      void report() => onProgress?.call(
        AssetDownloadProgress(written: written, total: total, etag: etag),
      );
      for (
        var chunk = await answer.body.next();
        chunk != null;
        chunk = await answer.body.next()
      ) {
        if (written + chunk.length > maxCiphertext) {
          throw tooLarge(answer.status);
        }
        if (total != null && written + chunk.length > total) {
          throw networkError(
            answer.status,
            'the body ran past its stated length',
          );
        }
        await sink.write(chunk);
        written += chunk.length;
        reported = true;
        report();
      }
      if (total != null && written != total) {
        throw networkError(answer.status, 'the body ended early');
      }
      if (!reported) report();
      return AssetDownloadResult(bytes: written, etag: etag);
    }

    Future<AssetDownloadResult> attempt() async {
      final resuming = written > 0 && etagToMatch != null;
      final ifRange = resuming && !_corsSafe && isStrongEtag(etagToMatch)
          ? etagToMatch
          : null;
      Answer answer;
      if (!resuming) {
        answer = await whole();
      } else {
        try {
          answer = await _requester.send(
            file.url,
            file.path,
            RequestSpec(
              'GET',
              RequestKind.range,
              from: written,
              ifRange: ifRange,
              noCache: cacheFlag,
            ),
          );
        } on AssetClientException catch (error) {
          if (!_corsSafe || !_isRejection(error)) rethrow;
          _logger.warn('asset ranged request refused; reading the whole file', {
            'path': loggablePath(file.path),
          });
          answer = await whole();
        }
      }
      try {
        return await consume(answer, ifRange != null);
      } finally {
        await answer.body.cancel();
      }
    }

    return _restarting(file, attempt, () async {
      if (written > 0) await sink.reset();
      written = 0;
      etagToMatch = null;
    });
  }

  @override
  Future<Uint8List> read(String path, {bool noCache = false}) async =>
      _readWhole(_fileOf(path), noCache);

  @override
  Future<Object?> readJson(String path, {bool noCache = false}) async {
    final bytes = await _readWhole(_fileOf(path), noCache);
    String text;
    try {
      text = const Utf8Decoder().convert(bytes);
    } on FormatException {
      throw corrupt();
    }
    // A byte-order mark is not JSON; `TextDecoder` drops it in tslib.
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    // Never quoted: a parse failure would carry the plaintext.
    return switch (Json.tryDecodeBig(text)) {
      JsonDecoded(:final value) => value,
      JsonRefused() => throw corrupt(),
    };
  }

  @override
  Future<Uint8List> readRange(
    String path, {
    required int start,
    int? end,
    bool noCache = false,
  }) async {
    final file = _fileOf(path);
    _checkOffset(start, 'range start');
    if (end != null) _checkOffset(end, 'range end');
    if (end != null && end <= start) return Uint8List(0);
    return _encrypted
        ? _readEncryptedRange(file, start, end, noCache)
        : _readPlainRange(file, start, end, noCache);
  }

  @override
  Future<AssetDownloadResult> download(
    String path, {
    required AssetSink sink,
    AssetResume? resume,
    void Function(AssetDownloadProgress progress)? onProgress,
    bool noCache = false,
  }) async {
    final file = _fileOf(path);
    var offset = 0;
    String? etag;
    if (resume != null) {
      offset = _checkOffset(resume.offset, 'resume offset');
      if (resume.etag.isEmpty) {
        throw ArgumentError('asset resume etag must not be empty');
      }
      etag = resume.etag;
    }
    return _encrypted
        ? _downloadEncrypted(file, sink, onProgress, offset, etag, noCache)
        : _downloadPlain(file, sink, onProgress, offset, etag, noCache);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _crypto?.close();
    if (_ownsHttp) _http.close();
  }
}
