/// Bounded JSON decoding and encoding for the yyt client libraries.
///
/// `dart:convert` does the parsing; this package adds what a client facing a
/// network peer needs on top of it: a length cap checked before parsing, a
/// depth cap, a non-throwing entry point, failures that carry a code and an
/// offset but never a quote of the input, and an object builder that keeps
/// "absent" and "JSON null" apart.
library;

export 'src/json.dart'
    show
        Json,
        JsonDecodeResult,
        JsonDecoded,
        JsonDepthError,
        JsonEncodeError,
        JsonList,
        JsonObject,
        JsonObjectBuilder,
        JsonParseError,
        JsonParseException,
        JsonParseFailure,
        JsonReading,
        JsonRefused;
