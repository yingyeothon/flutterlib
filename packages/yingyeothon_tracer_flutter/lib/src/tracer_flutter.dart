import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';
import 'package:yingyeothon_tracer_client/yingyeothon_tracer_client.dart';

/// Build-time values, read from `--dart-define`s. Nothing here is committed:
/// `TRACER_DSN="$(yyt tracer dsn <res>)"` and `GIT_SHA="$(git rev-parse
/// --short HEAD)"` come from the build command or a git-ignored
/// `--dart-define-from-file`.
abstract final class TracerDefines {
  /// `--dart-define=TRACER_DSN=…`; empty when not given (tracer off).
  static const String dsn = String.fromEnvironment('TRACER_DSN');

  /// `--dart-define=GIT_SHA=…`; empty when not given.
  static const String gitSha = String.fromEnvironment('GIT_SHA');
}

/// One-call setup per isolate. The UI isolate gets error, lifecycle and
/// screenshot support; a background isolate gets a plain client. Both make
/// the client [Tracer.current].
abstract final class TracerFlutter {
  static FlutterExceptionHandler? _previousFlutterError;
  static ui.ErrorCallback? _previousPlatformError;
  static FlutterExceptionHandler? _ownFlutterError;
  static ui.ErrorCallback? _ownPlatformError;
  static AppLifecycleListener? _lifecycle;
  static bool _installed = false;

  /// Initialises tracer in the UI isolate and returns the client.
  ///
  /// [gitSha] becomes the `git_sha` tag and, unless [dist] is given, the
  /// `dist`, so a reader can check out the exact build. Unless
  /// [captureErrors] is false, `FlutterError.onError` and
  /// `PlatformDispatcher.onError` gain a breadcrumb (with the error text)
  /// and a log line (its type only), then call the handlers they replaced;
  /// this is **not** crash reporting (keep the app's own crash reporter).
  /// Unless [lifecycle] is false, app lifecycle changes are breadcrumbs and
  /// `hidden`, `paused` and `detached` flush. `http` to a loopback host is
  /// allowed in debug builds only. In a release build the client is off
  /// unless [enableInRelease] is true, even if a DSN was compiled in.
  ///
  /// Calling it again replaces the client; the hooks are installed by the
  /// first call that turns tracer on and keep that call's choices.
  static TracerClient initUi({
    String dsn = TracerDefines.dsn,
    String? release,
    String? dist,
    String? environment,
    String gitSha = TracerDefines.gitSha,
    Map<String, String> tags = const {},
    String? userId,
    Map<String, Object?> contexts = const {},
    bool captureErrors = true,
    bool lifecycle = true,
    bool enableInRelease = false,
    http.Client? client,
    Logger? logger,
  }) {
    WidgetsFlutterBinding.ensureInitialized();
    final tracer = Tracer.initWith(
      _options(
        dsn: kReleaseMode && !enableInRelease ? '' : dsn,
        release: release,
        dist: dist,
        environment: environment,
        gitSha: gitSha,
        tags: {...tags, 'isolate': 'ui'},
        userId: userId,
        contexts: contexts,
        client: client,
        logger: logger,
      ),
    );
    if (tracer.enabled && !_installed) {
      _installed = true;
      if (captureErrors) _installErrorHooks();
      if (lifecycle) {
        _lifecycle = AppLifecycleListener(onStateChange: _lifecycleChanged);
      }
    }
    return tracer;
  }

  /// Initialises tracer in a background isolate (no widgets, no hooks) and
  /// returns the client; tagged `isolate` = [isolate]. Each isolate has its
  /// own client and breadcrumb ring; `--dart-define`s reach every isolate.
  /// `close()` it before the isolate ends, or its buffered lines are lost.
  /// Off in a release build unless [enableInRelease] is true.
  static TracerClient initBackground({
    String dsn = TracerDefines.dsn,
    String? release,
    String? dist,
    String? environment,
    String gitSha = TracerDefines.gitSha,
    String isolate = 'bg',
    Map<String, String> tags = const {},
    String? userId,
    Map<String, Object?> contexts = const {},
    bool enableInRelease = false,
    http.Client? client,
    Logger? logger,
  }) => Tracer.initWith(
    _options(
      dsn: kReleaseMode && !enableInRelease ? '' : dsn,
      release: release,
      dist: dist,
      environment: environment,
      gitSha: gitSha,
      tags: {...tags, 'isolate': isolate},
      userId: userId,
      contexts: contexts,
      client: client,
      logger: logger,
    ),
  );

  /// Restores the error handlers [initUi] replaced — only where its own are
  /// still installed, so a handler set later (a crash reporter's) stays —
  /// removes the lifecycle listener and closes [Tracer.current]. For tests
  /// and hot restarts.
  static Future<void> dispose() async {
    if (_installed) {
      if (_ownFlutterError != null &&
          identical(FlutterError.onError, _ownFlutterError)) {
        FlutterError.onError = _previousFlutterError;
      }
      final dispatcher = ui.PlatformDispatcher.instance;
      if (_ownPlatformError != null &&
          identical(dispatcher.onError, _ownPlatformError)) {
        dispatcher.onError = _previousPlatformError;
      }
      _previousFlutterError = null;
      _previousPlatformError = null;
      _ownFlutterError = null;
      _ownPlatformError = null;
      _lifecycle?.dispose();
      _lifecycle = null;
      _installed = false;
    }
    await Tracer.current.close();
  }

  static TracerOptions _options({
    required String dsn,
    required String? release,
    required String? dist,
    required String? environment,
    required String gitSha,
    required Map<String, String> tags,
    required String? userId,
    required Map<String, Object?> contexts,
    required http.Client? client,
    required Logger? logger,
  }) => TracerOptions(
    dsn: dsn,
    release: release,
    dist: dist ?? (gitSha.isEmpty ? null : gitSha),
    environment: environment ?? (kDebugMode ? 'debug' : null),
    tags: {if (gitSha.isNotEmpty) 'git_sha': gitSha, ...tags},
    userId: userId,
    contexts: {
      'os': {'name': defaultTargetPlatform.name},
      ...contexts,
    },
    client: client,
    logger: logger,
    allowHttpLoopback: kDebugMode,
  );

  /// A breadcrumb with the error's text (it stays on the device until a
  /// report) and a log line with its type only.
  static void _error(String category, Object error, String text) {
    final tracer = Tracer.current;
    final type = error.runtimeType.toString();
    tracer.breadcrumb(
      category,
      text,
      data: {'type': type},
      level: TracerLevel.error,
    );
    tracer.log(TracerLevel.error, category, attributes: {'type': type});
  }

  static void _installErrorHooks() {
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = _ownFlutterError = (details) {
      _error('flutter.error', details.exception, details.exceptionAsString());
      final previous = _previousFlutterError;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    final dispatcher = ui.PlatformDispatcher.instance;
    _previousPlatformError = dispatcher.onError;
    dispatcher.onError = _ownPlatformError = (error, stack) {
      String text;
      try {
        text = error.toString();
      } on Object {
        text = error.runtimeType.toString();
      }
      _error('platform.error', error, text);
      return _previousPlatformError?.call(error, stack) ?? false;
    };
  }

  static void _lifecycleChanged(AppLifecycleState state) {
    final tracer = Tracer.current;
    tracer.breadcrumb('app.lifecycle', state.name);
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(tracer.flush());
    }
  }
}

/// Navigation breadcrumbs (`navigation`, `push /board`, `{from, to}`).
/// Add it to `MaterialApp.navigatorObservers`.
class TracerNavigatorObserver extends NavigatorObserver {
  /// Observes for [client], or [Tracer.current] at each event.
  TracerNavigatorObserver({this.client});

  /// The client to write to; null means [Tracer.current].
  final TracerClient? client;

  void _crumb(String action, Route<dynamic>? to, Route<dynamic>? from) {
    final name = to?.settings.name;
    (client ?? Tracer.current).breadcrumb(
      'navigation',
      '$action ${name ?? '(anonymous)'}',
      data: {
        if (from?.settings.name != null) 'from': from!.settings.name,
        'to': ?name,
      },
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _crumb('push', route, previousRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _crumb('pop', previousRoute, route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _crumb('replace', newRoute, oldRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _crumb('remove', previousRoute, route);
}

/// Wraps the app in a [RepaintBoundary] that [capture] reads. Put it
/// around `MaterialApp` (or its `builder` child) once.
class TracerScreenshot extends StatelessWidget {
  /// Wraps [child].
  const TracerScreenshot({super.key, required this.child});

  /// The app.
  final Widget child;

  static final GlobalKey _boundary = GlobalKey(debugLabel: 'tracer');

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _boundary, child: child);

  /// A PNG of what [TracerScreenshot] shows, or null when it is not on
  /// screen or the capture fails. [pixelRatio] 1 keeps it small.
  static Future<Uint8List?> capture({double pixelRatio = 1}) async {
    try {
      final boundary = _boundary.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary || !boundary.attached) {
        return null;
      }
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } on Object {
      return null;
    }
  }

  /// The widget tree under [TracerScreenshot] (or the whole app when it is
  /// absent) as Sentry's view-hierarchy JSON: widget type, depth, the key's
  /// type, position and size; no text and no key values. At most [maxNodes]
  /// nodes; a failure gives an empty `windows` list.
  static Uint8List viewHierarchy({int maxNodes = 2000}) {
    try {
      return _viewHierarchy(maxNodes);
    } on Object {
      return utf8.encode('{"rendering_system":"flutter","windows":[]}');
    }
  }

  static Uint8List _viewHierarchy(int maxNodes) {
    final root =
        _boundary.currentContext as Element? ??
        WidgetsBinding.instance.rootElement;
    var budget = maxNodes;
    Map<String, Object?> node(Element e, int depth) {
      budget--;
      final render = e.renderObject;
      final children = <Map<String, Object?>>[];
      e.visitChildElements((child) {
        if (budget > 0 && depth < 200) children.add(node(child, depth + 1));
      });
      final box = render is RenderBox && render.attached && render.hasSize
          ? render
          : null;
      final origin = box?.localToGlobal(Offset.zero);
      return {
        'type': e.widget.runtimeType.toString(),
        'depth': depth,
        // The key's type only: a ValueKey's value may be user data.
        if (e.widget.key != null)
          'identifier': e.widget.key.runtimeType.toString(),
        'x': ?origin?.dx,
        'y': ?origin?.dy,
        'width': ?box?.size.width,
        'height': ?box?.size.height,
        if (children.isNotEmpty) 'children': children,
      };
    }

    final windows = root == null
        ? const <Map<String, Object?>>[]
        : [node(root, 1)];
    return utf8.encode(
      jsonEncode({'rendering_system': 'flutter', 'windows': windows}),
    );
  }
}

/// "Report this", debug builds only: a bug button that sends an event with
/// a screenshot and the view hierarchy, then asks for a note and sends it as
/// feedback linked to that event. In a release build it is
/// [SizedBox.shrink] and does nothing.
///
/// The note dialog needs a [Navigator]: place the button below one, or pass
/// [navigatorKey] when it sits above (in `MaterialApp.builder`).
class TracerReportButton extends StatelessWidget {
  /// A button for [client], or [Tracer.current].
  const TracerReportButton({
    super.key,
    this.client,
    this.message = 'report this',
    this.navigatorKey,
  });

  /// The client to send with; null means [Tracer.current].
  final TracerClient? client;

  /// The event message.
  final String message;

  /// The app's navigator, for a button placed above it.
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: 'Report this to tracer',
      child: GestureDetector(
        key: const Key('tracer-report'),
        onTap: () => reportThis(
          navigatorKey?.currentContext ?? context,
          client: client,
          message: message,
        ),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            '\u{1F41E}',
            style: TextStyle(
              inherit: false,
              fontSize: 24,
              color: Color(0xFFCC0000),
            ),
          ),
        ),
      ),
    );
  }

  /// What the button does, for an app with its own trigger: send the event
  /// (screenshot and view hierarchy attached), then ask for a note in a
  /// dialog and send it as feedback. [context] must be below a [Navigator].
  /// Completes with the event id, or null when tracer is off or this is a
  /// release build.
  /// A second call while one is still running returns null at once.
  static Future<String?> reportThis(
    BuildContext context, {
    TracerClient? client,
    String message = 'report this',
  }) async {
    if (!kDebugMode || _reporting) return null;
    final tracer = client ?? Tracer.current;
    if (!tracer.enabled) return null;
    _reporting = true;
    try {
      return await _report(context, tracer, message);
    } finally {
      _reporting = false;
    }
  }

  static bool _reporting = false;

  static Future<String?> _report(
    BuildContext context,
    TracerClient tracer,
    String message,
  ) async {
    final png = await TracerScreenshot.capture();
    final id = await tracer.report(
      message,
      screenshot: png,
      attachments: [
        TracerAttachment.viewHierarchy(TracerScreenshot.viewHierarchy()),
      ],
    );
    if (id == null || !context.mounted) return id;
    final note = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'tracer note',
      pageBuilder: (_, _, _) => const _NoteDialog(),
    );
    if (note != null && note.trim().isNotEmpty) {
      await tracer.feedback(note.trim(), eventId: id);
    }
    return id;
  }
}

/// The note prompt; widgets only, so it works without Material.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog();

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Not inherited: under MaterialApp without a Material ancestor the
    // default style is the red "missing Material" one.
    const ink = TextStyle(
      inherit: false,
      color: Color(0xFF000000),
      fontSize: 16,
      decoration: TextDecoration.none,
    );
    return Padding(
      // Keep "Send note" above the soft keyboard.
      padding: MediaQuery.viewInsetsOf(context),
      child: Center(
        child: DefaultTextStyle(
          style: ink,
          child: Container(
            width: 320,
            padding: const EdgeInsets.all(16),
            color: const Color(0xFFFFFFFF),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('What went wrong? (sent as feedback)', style: ink),
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  padding: const EdgeInsets.all(4),
                  color: const Color(0xFFEEEEEE),
                  child: EditableText(
                    key: const Key('tracer-note'),
                    controller: _text,
                    focusNode: _focus,
                    autofocus: true,
                    maxLines: 4,
                    minLines: 2,
                    style: ink,
                    cursorColor: const Color(0xFF000000),
                    backgroundCursorColor: const Color(0xFF888888),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    GestureDetector(
                      key: const Key('tracer-note-cancel'),
                      onTap: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('Cancel'),
                      ),
                    ),
                    GestureDetector(
                      key: const Key('tracer-note-send'),
                      onTap: () => Navigator.of(context).pop(_text.text),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          'Send note',
                          style: ink.copyWith(color: const Color(0xFF0000CC)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
