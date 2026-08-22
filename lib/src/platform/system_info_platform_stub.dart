library;

import 'system_info_types.dart';

SystemInfoData snapshot() => const SystemInfoData(
      operatingSystem: 'unknown',
      operatingSystemVersion: '',
      hostname: '',
      userName: '',
      locale: '',
      processorCount: 1,
    );

Future<bool?> isDarkMode() async => null;
