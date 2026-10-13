import 'package:web/web.dart' as web;

/// What the browser says it runs on. `navigator.platform` is deprecated but is
/// still the field every engine fills with `MacIntel`, `iPhone` or `iPad`, and
/// the user-agent is the fallback for an iPad that reports itself as a Mac.
bool detectsApplePlatform() {
  final web.Navigator navigator = web.window.navigator;
  final String platform = navigator.platform;
  if (platform.startsWith('Mac') ||
      platform.startsWith('iPhone') ||
      platform.startsWith('iPad')) {
    return true;
  }
  final String agent = navigator.userAgent;
  return agent.contains('Macintosh') ||
      agent.contains('iPhone') ||
      agent.contains('iPad');
}

/// The desktop under the browser, by the same evidence as
/// [detectsApplePlatform].
String detectedOperatingSystem() {
  if (detectsApplePlatform()) return 'macos';
  final String agent = web.window.navigator.userAgent;
  if (agent.contains('Windows')) return 'windows';
  if (agent.contains('Android')) return 'android';
  return 'linux';
}
