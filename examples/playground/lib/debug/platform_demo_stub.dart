/// Offline servers require dart:io; web builds can use a running fake remotely.
Future<List<String>> runPlatformDemo() async => [
  'Offline server unavailable on web',
];
