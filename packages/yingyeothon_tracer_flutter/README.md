# yingyeothon_tracer_flutter

Flutter glue for [`yingyeothon_tracer_client`](../yingyeothon_tracer_client): one
call per isolate to start tracer from `--dart-define`s, screenshots through a
`RepaintBoundary`, the view hierarchy as JSON, lifecycle, navigation and Flutter
error breadcrumbs, and a debug-only "report this" button that sends an event with a
screenshot and then the user's note as feedback. **The repository's one Flutter
package**: everything testable lives in the pure Dart core; this is the thin layer
that needs `package:flutter`.

The UI isolate's hooks feed the same client the button reports through:

```mermaid
flowchart LR
  init["TracerFlutter.initUi"] --> client["Tracer.current"]
  errors["FlutterError, PlatformDispatcher"] --> client
  life["AppLifecycleListener"] --> client
  nav["TracerNavigatorObserver"] --> client
  button["TracerReportButton"] --> shot["TracerScreenshot"]
  shot --> client
  client --> tracer["tracer ingest"]
```

## Install

```yaml
dependencies:
  yingyeothon_tracer_flutter:
    git:
      url: https://github.com/yingyeothon/flutterlib.git
      path: packages/yingyeothon_tracer_flutter
      ref: v0.3.0 # the first tag with the tracer packages (not released yet; v0.2.0 does not contain them)
  yingyeothon_tracer_client:
    git:
      url: https://github.com/yingyeothon/flutterlib.git
      path: packages/yingyeothon_tracer_client
      ref: v0.3.0 # the first tag with the tracer packages (not released yet; v0.2.0 does not contain them)
```

Depend on both, on the same `ref:`: this package does not re-export the core
(`Tracer`, `TracerLevel`, …). The packages are on main, pending an owner-cut
release; the snippet names the existing release and does not claim that tag
contains them — until it does, point `ref:` at a commit of `main`.

## Usage

```dart
import 'package:flutter/material.dart';
import 'package:yingyeothon_tracer_flutter/yingyeothon_tracer_flutter.dart';

void main() {
  // TRACER_DSN and GIT_SHA from --dart-define; off when TRACER_DSN is absent.
  TracerFlutter.initUi(release: 'myapp@1.4.0+12');
  runApp(
    TracerScreenshot(
      child: MaterialApp(
        navigatorObservers: [TracerNavigatorObserver()],
        home: Scaffold(
          appBar: AppBar(actions: const [TracerReportButton()]),
          body: const Text('hello'),
        ),
      ),
    ),
  );
}
```

Build with
`--dart-define=TRACER_DSN="$(yyt tracer dsn <res>)" --dart-define=GIT_SHA="$(git rev-parse --short HEAD)"`,
or keep both in a git-ignored file for `--dart-define-from-file`. The DSN is never
committed.

## What each piece does

- `TracerFlutter.initUi` makes the client `Tracer.current` — off in a release
  build unless `enableInRelease: true`, even if a DSN was compiled in — tags it `isolate: ui`
  and `git_sha`, uses the sha as `dist` (unless you pass one), sets `environment:
  debug` in a debug build and `contexts.os.name`, and allows `http` to a loopback
  host only in a debug build. It chains `FlutterError.onError` and
  `PlatformDispatcher.onError` — each error becomes a breadcrumb with its text
  (which leaves the device only inside a report) and a log line with its type
  only, then the previous handler runs (or `FlutterError.presentError` when there
  was none) — and turns lifecycle changes into breadcrumbs, flushing on `hidden`,
  `paused` and `detached`. Errors your own `runZonedGuarded` catches never reach
  these hooks.
  **This is not crash reporting**: keep your crash reporter; the two do not know
  about each other. Calling it again swaps the client and keeps one set of hooks
  (with the first enabled call's `captureErrors` and `lifecycle`).
- `TracerFlutter.initBackground` builds a plain client for a background isolate,
  tagged `isolate: bg` (or yours). Each isolate has its own client and ring;
  `close()` it before the isolate ends, or its buffered lines are lost.
- `TracerFlutter.dispose` restores the replaced handlers where its own are still
  installed (a crash reporter's later handler stays) and closes the client.
- `TracerScreenshot` wraps the app **once** (its key is global); `capture()`
  returns a PNG (pixel ratio 1) or null, `viewHierarchy()` the widget tree as
  Sentry's view-hierarchy JSON (type, depth, the key's type, position, size; no
  text and no key values; at most 2000 nodes).
- `TracerNavigatorObserver` writes `navigation` breadcrumbs (`push /board`,
  `{from, to}`).
- `TracerReportButton` is a bug button in a debug build and nothing in a release
  build. A tap sends `report` with the screenshot and the view hierarchy, then asks
  for a note (Send or Cancel) and sends it as `feedback` linked to that event. A
  second tap while one runs does nothing; profile builds have no button either.
  `TracerReportButton.reportThis` does the same from your own trigger. The note
  dialog needs a `Navigator` below the trigger, or `navigatorKey` for a button that
  sits above it.

## Beside a Sentry crash setup

Keep the app's Sentry init for crashes; initialise tracer next to it. To copy
Sentry's automatic breadcrumbs into tracer, mirror them in one line (`Tracer` is
in `yingyeothon_tracer_client`, which this package does not re-export):

```dart
options.beforeBreadcrumb = (crumb, hint) {
  Tracer.current.breadcrumb(
    crumb?.category ?? 'sentry',
    crumb?.message ?? '',
    data: crumb?.data,
  );
  return crumb;
};
```

Nothing depends on it, and neither package imports the other. It also copies
Sentry's own navigation and lifecycle crumbs, so drop tracer's observer or
lifecycle hook (`lifecycle: false`) if you mirror.

## Public API

- `TracerFlutter` (`initUi`, `initBackground`, `dispose`), `TracerDefines` (`dsn`,
  `gitSha`).
- `TracerScreenshot` (`capture`, `viewHierarchy`), `TracerNavigatorObserver`,
  `TracerReportButton` (`reportThis`).

## Differences from @yingyeothon/tracer-client and Yingyeothon.TracerClient

- Neither exists yet. Their platform extras (`window.onerror`, Unity's
  `ScreenCapture`) play the role this package plays for Flutter
  (`docs/tracer.md` in the service repository).
- It is the only `yingyeothon_*` package that imports `package:flutter`, an owner
  decision of 2026-11-08: screenshots and the widget tree cannot be read without
  it. It stays outside the pub workspace, like the example.
