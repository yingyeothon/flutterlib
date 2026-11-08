/// Flutter glue for yyt tracer over `yingyeothon_tracer_client`: one-call
/// setup per isolate, screenshots and view hierarchy, lifecycle, navigation
/// and error breadcrumbs, and a debug-only "report this" button.
library;

// The core comes with it: a Flutter app depends on this one package. Two git
// dependencies on the same tag do not resolve (pub reads this package's
// `path:` sibling as the tag's commit, a different source from `ref: vX`).
export 'package:yingyeothon_tracer_client/yingyeothon_tracer_client.dart'
    show
        Tracer,
        TracerAttachment,
        TracerClient,
        TracerDsn,
        TracerLevel,
        TracerLimits,
        TracerLogWriter,
        TracerOptions,
        TracerState,
        TracerStats,
        tracerSdkVersion;

export 'src/tracer_flutter.dart'
    show
        TracerDefines,
        TracerFlutter,
        TracerNavigatorObserver,
        TracerReportButton,
        TracerScreenshot;
