final class DrumPadSpec {
  const DrumPadSpec({
    required this.name,
    required this.subtitle,
    required this.keyLabel,
    required this.logicalKey,
    required this.fileName,
    required this.color,
    this.gain = 1,
    this.chokeGroup = -1,
  });

  final String name;
  final String subtitle;
  final String keyLabel;
  final int logicalKey;
  final String fileName;
  final int color;
  final double gain;
  final int chokeGroup;
}

const List<DrumPadSpec> drumKit = <DrumPadSpec>[
  DrumPadSpec(
    name: 'KICK 01',
    subtitle: 'Acoustic punch',
    keyLabel: 'A',
    logicalKey: 0x41,
    fileName: 'kick-acoustic01.wav',
    color: 0xFFFC5C65,
    gain: 1.05,
  ),
  DrumPadSpec(
    name: 'KICK 02',
    subtitle: 'Deep body',
    keyLabel: 'S',
    logicalKey: 0x53,
    fileName: 'kick-acoustic02.wav',
    color: 0xFFFF7B54,
    gain: 1.05,
  ),
  DrumPadSpec(
    name: 'SNARE 01',
    subtitle: 'Tight acoustic',
    keyLabel: 'D',
    logicalKey: 0x44,
    fileName: 'snare-acoustic01.wav',
    color: 0xFFFFB84D,
  ),
  DrumPadSpec(
    name: 'SNARE 02',
    subtitle: 'Wide acoustic',
    keyLabel: 'F',
    logicalKey: 0x46,
    fileName: 'snare-acoustic02.wav',
    color: 0xFFFFD166,
  ),
  DrumPadSpec(
    name: 'HI-HAT 01',
    subtitle: 'Closed / short',
    keyLabel: 'G',
    logicalKey: 0x47,
    fileName: 'hihat-acoustic01.wav',
    color: 0xFF42D392,
    gain: 0.82,
    chokeGroup: 1,
  ),
  DrumPadSpec(
    name: 'HI-HAT 02',
    subtitle: 'Closed / bright',
    keyLabel: 'H',
    logicalKey: 0x48,
    fileName: 'hihat-acoustic02.wav',
    color: 0xFF38C6A3,
    gain: 0.82,
    chokeGroup: 1,
  ),
  DrumPadSpec(
    name: 'OPEN HAT',
    subtitle: 'Acoustic open',
    keyLabel: 'J',
    logicalKey: 0x4A,
    fileName: 'openhat-acoustic01.wav',
    color: 0xFF26BBD3,
    gain: 0.78,
    chokeGroup: 1,
  ),
  DrumPadSpec(
    name: 'TOM 01',
    subtitle: 'High tom',
    keyLabel: 'K',
    logicalKey: 0x4B,
    fileName: 'tom-acoustic01.wav',
    color: 0xFF4D9DE0,
  ),
  DrumPadSpec(
    name: 'TOM 02',
    subtitle: 'Low tom',
    keyLabel: 'L',
    logicalKey: 0x4C,
    fileName: 'tom-acoustic02.wav',
    color: 0xFF6574E8,
  ),
  DrumPadSpec(
    name: 'CRASH',
    subtitle: 'Acoustic cymbal',
    keyLabel: 'Q',
    logicalKey: 0x51,
    fileName: 'crash-acoustic.wav',
    color: 0xFF9B6DE3,
    gain: 0.72,
  ),
  DrumPadSpec(
    name: 'RIDE 01',
    subtitle: 'Bell definition',
    keyLabel: 'W',
    logicalKey: 0x57,
    fileName: 'ride-acoustic01.wav',
    color: 0xFFC66DE3,
    gain: 0.72,
  ),
  DrumPadSpec(
    name: 'RIDE 02',
    subtitle: 'Long sustain',
    keyLabel: 'E',
    logicalKey: 0x45,
    fileName: 'ride-acoustic02.wav',
    color: 0xFFE56FB5,
    gain: 0.72,
  ),
];
