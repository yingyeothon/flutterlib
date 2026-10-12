import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'internal/push_client_impl.dart';

/// An incoming device message; payloads must never be logged.
final class PushMessage {
  /// Copies message data. Notification text is optional.
  PushMessage({required Map<String, String> data, this.title, this.body})
    : data = Map.unmodifiable(data);

  /// The FCM data object.
  final Map<String, String> data;

  /// Optional notification title.
  final String? title;

  /// Optional notification body.
  final String? body;
}

/// Device SDK seam. The Firebase implementation belongs to the host app.
abstract interface class PushMessaging {
  /// Current FCM token, or null until permission/registration succeeds.
  Future<String?> getToken();

  /// Token rotations that need re-registration.
  Stream<String> get tokenRefreshed;

  /// Foreground deliveries and notification taps, including initial taps.
  Stream<PushMessage> get messages;

  /// Subscribes the device to the configured public topic.
  Future<void> subscribe(String topic);

  /// Removes the topic subscription.
  Future<void> unsubscribe(String topic);
}

/// Safe failure for a push token request or messaging adapter operation.
final class PushException implements Exception {
  /// Creates a failure.
  const PushException(this.status, this.code, {this.reason});

  /// HTTP status, zero for transport/device errors.
  final int status;

  /// Validated service code or fixed local code.
  final String code;

  /// Validated service reason word, never the body.
  final String? reason;
  @override
  String toString() => 'PushException($code, $status)';
}

/// Incoming messages classified for routing without trusting them as state.
sealed class ClassifiedPush {
  const ClassifiedPush(this.message);

  /// Original message; never log it.
  final PushMessage message;
}

/// A match wake hints that a ticket should be read from the service.
final class MatchPush extends ClassifiedPush {
  /// Creates a wake.
  const MatchPush(
    super.message, {
    required this.channelId,
    required this.matchId,
    required this.state,
  });

  /// Match channel, not push channel.
  final String channelId;

  /// Match hint, empty for a wait timeout; never authoritative.
  final String matchId;

  /// State hint; always re-read the ticket.
  final String state;
}

/// Campaign, broadcast or application-defined delivery.
final class MessagePush extends ClassifiedPush {
  /// Creates an application delivery.
  const MessagePush(super.message);
}

/// Classifies data from both foreground receipt and notification tap.
ClassifiedPush classifyPush(PushMessage message) {
  final data = message.data;
  final channel = data['channelId'];
  final match = data['matchId'];
  final state = data['state'];
  if (channel != null &&
      channel.isNotEmpty &&
      match != null &&
      ['proposed', 'confirmed', 'expired', 'failed'].contains(state)) {
    return MatchPush(
      message,
      channelId: channel,
      matchId: match,
      state: state!,
    );
  }
  return MessagePush(message);
}

/// Options for one credential and push channel. Android/FCM only.
final class PushClientOptions {
  /// Creates options. The topic is copied from kit-config, never constructed.
  const PushClientOptions({
    required this.apiBase,
    required this.channelId,
    required this.token,
    required this.topic,
    required this.project,
    this.messaging,
    this.client,
    this.logger,
    this.timeout = const Duration(seconds: 15),
  });

  /// State API base.
  final Uri apiBase;

  /// Push channel identifier.
  final String channelId;

  /// JWT of the channel's linked auth channel.
  final String token;

  /// Public broadcast topic from kit-config.
  final String topic;

  /// Firebase project id embedded by the app's configuration.
  final String project;

  /// Optional device SDK. Null allows manual register/unregister only.
  final PushMessaging? messaging;

  /// Injected HTTP client; never closed here.
  final http.Client? client;

  /// Diagnostics, default nullLogger.
  final Logger? logger;

  /// Headers-and-body deadline.
  final Duration timeout;
}

/// Registers Android devices and routes messages; exposes no server send API.
abstract interface class PushClient {
  /// Creates a client without requesting device permission or registering.
  factory PushClient(PushClientOptions options) = PushClientImpl;

  /// Registers on every app start, then listens for refreshes and messages.
  Future<void> start();

  /// Registers a token and subscribes the device after a successful request.
  Future<void> register(String deviceToken);

  /// Unregisters the last token and unsubscribes. Call before discarding JWT.
  Future<void> unregister();

  /// Classified deliveries; a match wake never grants an entitlement.
  Stream<ClassifiedPush> get received;

  /// Async token refresh/device failures, without secrets.
  Stream<PushException> get refused;

  /// Stops subscriptions and closes owned resources; does not unregister.
  Future<void> close();
}
