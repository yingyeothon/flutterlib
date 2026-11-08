/// Flutter glue for yyt tracer over `yingyeothon_tracer_client`: one-call
/// setup per isolate, screenshots and view hierarchy, lifecycle, navigation
/// and error breadcrumbs, and a debug-only "report this" button.
library;

export 'src/tracer_flutter.dart'
    show
        TracerDefines,
        TracerFlutter,
        TracerNavigatorObserver,
        TracerReportButton,
        TracerScreenshot;
