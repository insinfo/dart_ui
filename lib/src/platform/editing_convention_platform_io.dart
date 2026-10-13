import 'dart:io' show Platform;

bool detectsApplePlatform() => Platform.isMacOS || Platform.isIOS;

/// `macos`, `windows`, `linux`, ... - [Platform.operatingSystem].
String detectedOperatingSystem() => Platform.operatingSystem;
