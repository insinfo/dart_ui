/// Representa uma tabela CMap (Character Map) do PDF, usada primariamente em fontes
/// Tipo 0 (Composite Fonts / CIDFonts) para mapear códigos de string do conteúdo (CIDs)
/// para valores Unicode válidos ou CIDs brutos.
class PdfCMap {
  final String cmapName;
  final Map<int, int> _cidToUnicode = {};

  // Fontes CID podem ter mapeamentos de intervalos complexos
  final List<_CMapRange> _ranges = [];

  PdfCMap({this.cmapName = 'Identity-H'});

  /// Adiciona um mapeamento individual bfchar: <srcCode> <dstUnicode>
  void addBfChar(int srcCode, int dstUnicode) {
    _cidToUnicode[srcCode] = dstUnicode;
  }

  /// Adiciona um mapeamento de intervalo bfrange: <srcCode1> <srcCode2> <dstUnicode1>
  void addBfRange(int srcStart, int srcEnd, int dstStart) {
    _ranges.add(_CMapRange(srcStart, srcEnd, dstStart));
  }

  /// Mapeia o Character ID (CID) para o código Unicode correspondente.
  int? getUnicode(int cid) {
    // 1. Busca exata (bfchar)
    if (_cidToUnicode.containsKey(cid)) {
      return _cidToUnicode[cid];
    }

    // 2. Busca em intervalos (bfrange)
    for (final range in _ranges) {
      if (cid >= range.srcStart && cid <= range.srcEnd) {
        final offset = cid - range.srcStart;
        return range.dstStart + offset;
      }
    }

    return null;
  }
}

class _CMapRange {
  final int srcStart;
  final int srcEnd;
  final int dstStart;

  _CMapRange(this.srcStart, this.srcEnd, this.dstStart);
}
