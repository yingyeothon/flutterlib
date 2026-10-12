/// Purpose-shaped yyt game modules; wire APIs remain in their own packages.
library;

export 'src/game_kit.dart'
    show
        GameKitConfig,
        KitError,
        KitMerge,
        KitQueuedWrite,
        KitQueueStorage,
        GameKitOptions,
        GameKit,
        KitContent,
        KitSave,
        KitCounter,
        KitMember,
        KitRoomEvent,
        KitInvitation,
        KitRoom,
        KitTurns,
        KitTurnGame,
        KitTurnEvent,
        KitScore,
        KitBoard,
        KitLetter,
        KitMail,
        KitFriend,
        KitFriendRequests,
        KitFriends,
        KitMatch,
        KitMatchStatus,
        KitMatchmaking,
        KitMessage,
        KitPush;
export 'src/kit_json.dart' show KitJson;
