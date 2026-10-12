import 'dart:io' show Platform;

bool detectsApplePlatform() => Platform.isMacOS || Platform.isIOS;
