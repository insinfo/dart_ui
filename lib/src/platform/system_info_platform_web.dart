library;

import 'package:web/web.dart' as web;

import 'system_info_types.dart';

SystemInfoData snapshot() {
  final web.Navigator navigator = web.window.navigator;
  return SystemInfoData(
    operatingSystem: 'web',
    // The user-agent is the only version string a browser offers, and it is
    // deliberately passed on verbatim; see [SystemInfoData].
    operatingSystemVersion: navigator.userAgent,
    hostname: web.window.location.hostname,
    userName: '',
    locale: navigator.language,
    processorCount:
        navigator.hardwareConcurrency > 0 ? navigator.hardwareConcurrency : 1,
  );
}

Future<bool?> isDarkMode() async =>
    web.window.matchMedia('(prefers-color-scheme: dark)').matches;
