/// Pure Dart client for yyt tracer, the platform's debug-data collector:
/// breadcrumbs, buffered logs, reports with screenshots, and feedback, sent
/// as envelopes to its Sentry-compatible ingest. No Flutter and no Sentry
/// dependency.
library;

export 'src/tracer_client.dart'
    show
        Tracer,
        TracerAttachment,
        TracerClient,
        TracerLevel,
        TracerLimits,
        TracerLogWriter,
        TracerOptions,
        TracerState,
        TracerStats,
        tracerSdkVersion;
export 'src/tracer_dsn.dart' show TracerDsn;
