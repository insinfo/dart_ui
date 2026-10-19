/// Initial-name buckets used by the Details header filter.
library;

enum NameRange {
  digits('0–9'),
  aToH('A–H'),
  iToP('I–P'),
  qToZ('Q–Z'),
  other('');

  const NameRange(this.label);
  final String label;

  /// Latin accents share their base letter's bucket. Other scripts and
  /// punctuation remain available through the explicit Other bucket.
  static NameRange of(String name) {
    if (name.isEmpty) return other;
    var initial = String.fromCharCode(name.runes.first).toUpperCase();
    const accents = {
      'A': 'ÀÁÂÃÄÅĀĂĄ',
      'C': 'ÇĆĈĊČ',
      'D': 'ÐĎĐ',
      'E': 'ÈÉÊËĒĔĖĘĚ',
      'G': 'ĜĞĠĢ',
      'H': 'ĤĦ',
      'I': 'ÌÍÎÏĨĪĬĮİ',
      'J': 'Ĵ',
      'K': 'Ķ',
      'L': 'ĹĻĽŁ',
      'N': 'ÑŃŅŇ',
      'O': 'ÒÓÔÕÖØŌŎŐ',
      'R': 'ŔŖŘ',
      'S': 'ŚŜŞŠ',
      'T': 'ŢŤŦ',
      'U': 'ÙÚÛÜŨŪŬŮŰŲ',
      'W': 'Ŵ',
      'Y': 'ÝŸŶ',
      'Z': 'ŹŻŽ',
    };
    for (final entry in accents.entries) {
      if (entry.value.contains(initial)) {
        initial = entry.key;
        break;
      }
    }
    final code = initial.codeUnitAt(0);
    if (code >= 48 && code <= 57) return digits;
    if (code >= 65 && code <= 72) return aToH;
    if (code >= 73 && code <= 80) return iToP;
    if (code >= 81 && code <= 90) return qToZ;
    return other;
  }
}
