import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

/// Android adapter; no Firebase initialization occurs on Linux, web or iOS.
final class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging._(this._sdk) {
    _messages = StreamController<PushMessage>.broadcast(
      onListen: _listen,
      onCancel: _unlisten,
    );
  }
  final FirebaseMessaging _sdk;
  late final StreamController<PushMessage> _messages;
  StreamSubscription<RemoteMessage>? _foreground;
  StreamSubscription<RemoteMessage>? _opened;
  bool _initialRead = false;
  bool _closed = false;
  bool registeredPermission = false;

  /// Returns null when Android/Firebase configuration is unavailable.
  static Future<FirebasePushMessaging?> connect() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    const apiKey = String.fromEnvironment('YYT_FIREBASE_API_KEY');
    const appId = String.fromEnvironment('YYT_FIREBASE_APP_ID');
    const sender = String.fromEnvironment('YYT_FIREBASE_SENDER_ID');
    const project = String.fromEnvironment('YYT_FIREBASE_PROJECT_ID');
    if ([apiKey, appId, sender, project].any((s) => s.isEmpty)) return null;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: apiKey,
            appId: appId,
            messagingSenderId: sender,
            projectId: project,
          ),
        );
      }
      return FirebasePushMessaging._(FirebaseMessaging.instance);
    } on Exception {
      return null;
    }
  }

  static PushMessage _message(RemoteMessage value) => PushMessage(
    data: {
      for (final entry in value.data.entries)
        if (entry.value is String) entry.key: entry.value as String,
    },
    title: value.notification?.title,
    body: value.notification?.body,
  );
  void _listen() {
    if (_closed) return;
    _foreground = FirebaseMessaging.onMessage.listen(
      (value) {
        if (!_closed) _messages.add(_message(value));
      },
      onError: (Object _) {
        if (!_closed) _messages.addError(const PushException(0, 'device'));
      },
    );
    _opened = FirebaseMessaging.onMessageOpenedApp.listen(
      (value) {
        if (!_closed) _messages.add(_message(value));
      },
      onError: (Object _) {
        if (!_closed) _messages.addError(const PushException(0, 'device'));
      },
    );
    if (!_initialRead) {
      _initialRead = true;
      unawaited(
        _sdk.getInitialMessage().then(
          (value) {
            if (value != null && !_closed) _messages.add(_message(value));
          },
          onError: (Object _) {
            if (!_closed) _messages.addError(const PushException(0, 'device'));
          },
        ),
      );
    }
  }

  Future<void> _unlisten() async {
    await _foreground?.cancel();
    await _opened?.cancel();
    _foreground = null;
    _opened = null;
  }

  @override
  Future<String?> getToken() async {
    final settings = await _sdk.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return null;
    final token = await _sdk.getToken();
    registeredPermission = token != null;
    return token;
  }

  @override
  Stream<String> get tokenRefreshed => _sdk.onTokenRefresh;
  @override
  Stream<PushMessage> get messages => _messages.stream;
  @override
  Future<void> subscribe(String topic) => _sdk.subscribeToTopic(topic);
  @override
  Future<void> unsubscribe(String topic) => _sdk.unsubscribeFromTopic(topic);
  Future<void> close() async {
    _closed = true;
    await _unlisten();
    await _messages.close();
  }
}
