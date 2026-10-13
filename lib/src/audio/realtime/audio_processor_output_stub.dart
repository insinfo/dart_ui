/// No realtime output where there is no `dart:io`.
library;

import '../audio_format.dart';
import 'audio_control_block.dart';
import 'audio_processor_output.dart';

Future<AudioProcessorOutput?> openAudioProcessorOutput(
  AudioProcessorBuilder build, {
  required AudioControlBlock? controls,
  required AudioFormat preferredFormat,
  required int? preferredPeriodFrames,
  required String debugName,
}) async =>
    null;
