/// A client for yyt social served by the state stack.
///
/// One [SocialClient] per credential: the channel JWT of a player, whose
/// own card, friends, requests and blocks the `me` routes are about, or the
/// auth channel's doc apiKey, which reads anyone, writes and deletes cards
/// and deletes relations, and never creates one. Social is scoped to the
/// auth channel: a project with two channels has two friend graphs.
///
/// Nothing here ever logs, throws, or returns a message that contains the
/// token, a player id, a display name, an avatar or a URL; a failure is a
/// status and a code.
library;

export 'src/errors.dart' show SocialException;
export 'src/rules.dart' show SocialRules;
export 'src/social_client.dart'
    show SocialClient, SocialClientOptions, SocialServerCommands;
export 'src/types.dart'
    show
        SocialProfile,
        SocialProfileResult,
        SocialRelation,
        SocialRelationState,
        SocialRequestResult,
        SocialRequests;
