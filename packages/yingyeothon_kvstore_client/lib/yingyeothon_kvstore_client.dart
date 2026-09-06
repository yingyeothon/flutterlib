/// A client for the yyt key-value store served by the state stack.
///
/// One [KvStoreClient] per credential: the channel JWT of a player or the
/// auth channel's doc apiKey of the game's server. It addresses a collection
/// by its console name or its `kv_` id, reads and writes JSON values by key
/// in the shared namespace or in one owner's namespace (`mine` for the
/// player), lists with a cursor, and increments a counter atomically.
///
/// Nothing here ever logs, throws, or returns a message that contains the
/// token, a key, a value or a URL; a failure is a status and a code.
library;

export 'src/errors.dart' show KvStoreException;
export 'src/kvstore_client.dart'
    show KvCollection, KvNamespace, KvStoreClient, KvStoreClientOptions;
export 'src/rules.dart' show KvRules;
export 'src/types.dart'
    show
        KvCollectionInfo,
        KvEntry,
        KvIncrResult,
        KvListEntry,
        KvOrder,
        KvPage,
        KvScope,
        KvWriteResult;
