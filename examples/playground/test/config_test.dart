import 'package:flutter_test/flutter_test.dart';
import 'package:yyt_playground/config.dart';

void main() {
  test('an unset dart-define is empty and cannot connect or sign in', () {
    const c = PlaygroundConfig.fromEnvironment;
    expect(c.gatewayUrl, isEmpty);
    expect(c.canConnect, isFalse);
    expect(c.canSignIn, isFalse);
  });

  test('copyWith fills the gaps', () {
    const c = PlaygroundConfig(
      gatewayUrl: '',
      channelId: '',
      authBaseUrl: 'https://auth.example',
      authChannelId: 'auth_x',
    );
    expect(c.canSignIn, isTrue);
    final next = c.copyWith(gatewayUrl: 'ws://h', channelId: 'lobby_x');
    expect(next.canConnect, isTrue);
    expect(next.authChannelId, 'auth_x');
  });
}
