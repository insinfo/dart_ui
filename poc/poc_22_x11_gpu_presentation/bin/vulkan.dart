import 'dart:io';

import 'package:poc_22_x11_gpu_presentation/poc_22_x11_gpu_presentation.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runPresentationCommand(
    arguments,
    forcedBackends: const <PresentationBackend>{PresentationBackend.vulkan},
  );
}
