/// The server's rules the client refuses locally, and nothing more.
///
/// Every constant is a copy of one in the `service` repository
/// (`packages/console-db/src/social.ts`, with the profile owner grammar from
/// `kvstore.ts`); when that file changes, this one follows. A local refusal
/// is a fast `ArgumentError` whose message names the rule and never the
/// input; the server is the enforcement.
abstract final class SocialRules {
  /// `SOCIAL_PLAYER_ID`: the other end of a relation is always a player.
  static final RegExp playerIdPattern = RegExp(r'^[0-9a-f]{32}$');

  /// `KV_OWNER_ID`: a profile's owner, which a server may make a guild
  /// (`{kind}:{id}`).
  static final RegExp profileOwnerPattern = RegExp(
    r'^(?:[0-9a-f]{32}|[a-z]{1,8}:[A-Za-z0-9_-]{1,48})$',
  );

  /// `SOCIAL_AVATAR`: an id or a path into the game's own asset table, never
  /// a URL.
  static final RegExp avatarPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,31}(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,31}){0,3}$',
  );

  /// `SOCIAL_DISPLAY_NAME_MAX`, in characters (code points) after trimming.
  static const int displayNameMax = 32;

  /// `SOCIAL_AVATAR_MAX`, in UTF-16 units as the server counts them.
  static const int avatarMax = 64;

  /// `SOCIAL_PROFILE_IDS_MAX`: ids per `profiles()` call.
  static const int profileIdsMax = 50;

  /// `SOCIAL_FRIENDS_MAX`.
  static const int friendsMax = 200;

  /// `SOCIAL_PENDING_OUT_MAX` and `SOCIAL_PENDING_IN_MAX`.
  static const int pendingMax = 100;

  /// `SOCIAL_BLOCKS_MAX`.
  static const int blocksMax = 500;

  /// What a display name may not contain: controls and format characters
  /// (`\p{Cc}`, `\p{Cf}`), the two line separators, and a run of five or
  /// more combining marks.
  static final RegExp _nameRefused = RegExp(
    r'[\p{Cc}\p{Cf}\u2028\u2029]|\p{Mn}{5,}',
    unicode: true,
  );

  /// Returns [id] when it is 32 hex characters; throws otherwise.
  static String checkPlayerId(String id) {
    if (playerIdPattern.hasMatch(id)) return id;
    throw ArgumentError('social player id must be 32 hex characters');
  }

  /// Returns [owner] when it is a player id or `{kind}:{id}`; throws
  /// otherwise.
  static String checkProfileOwner(String owner) {
    if (profileOwnerPattern.hasMatch(owner)) return owner;
    throw ArgumentError(
      'social profile owner must be 32 hex characters or kind:id',
    );
  }

  /// Returns [name] trimmed when it is 1 … [displayNameMax] characters with
  /// nothing the server refuses; throws otherwise. Never normalised further:
  /// a game's display string is the game's.
  static String checkDisplayName(String name) {
    final trimmed = name.trim();
    final length = trimmed.runes.length;
    if (length < 1 || length > displayNameMax) {
      throw ArgumentError(
        'social displayName must be 1 to $displayNameMax characters',
      );
    }
    if (_nameRefused.hasMatch(trimmed)) {
      throw ArgumentError(
        'social displayName must not contain control, format or line '
        'separator characters, or a run of combining marks',
      );
    }
    return trimmed;
  }

  /// Returns [avatar] when it is `null` or an id or path within
  /// [avatarMax]; throws otherwise.
  static String? checkAvatar(String? avatar) {
    if (avatar == null) return null;
    if (avatar.length <= avatarMax && avatarPattern.hasMatch(avatar)) {
      return avatar;
    }
    throw ArgumentError('social avatar must be a short id or path, not a URL');
  }

  /// Returns [ids] deduplicated when there are 1 … [profileIdsMax] of them
  /// and each is a profile owner; throws otherwise.
  static List<String> checkProfileIds(Iterable<String> ids) {
    final seen = <String>{};
    for (final id in ids) {
      seen.add(checkProfileOwner(id));
    }
    if (seen.isEmpty || seen.length > profileIdsMax) {
      throw ArgumentError('social profiles takes 1 to $profileIdsMax ids');
    }
    return seen.toList();
  }
}
