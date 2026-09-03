/// Structured logging with a severity threshold that can change at runtime.
///
/// Every yyt package takes a [Logger] as an option and defaults to
/// [nullLogger]. A structured context is a [JsonObject], so a writer renders
/// it without reflection and the same line looks the same on every platform.
library;

export 'src/logger.dart'
    show
        LogSeverity,
        LogWriteFunction,
        LogWriter,
        LogWriters,
        Logger,
        createConsoleLogger,
        createFilteredLogger,
        nullLogger;
