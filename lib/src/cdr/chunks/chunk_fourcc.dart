/// Constantes para assinaturas e blocos FourCC (Four-Character Codes)
/// utilizados nas estruturas RIFF (CorelDRAW clássico) e nos blocos binários.
class CdrFourCC {
  // Contêiner
  static const int riff = 0x46464952; // 'RIFF' little-endian
  static const int list = 0x5453494C; // 'LIST'

  // Tipos de Documento CDR
  static const int cdrV3 = 0x20524443; // 'CDR ' (v3)
  static const int cdrV4 = 0x34524443; // 'CDR4'
  static const int cdrV5 = 0x35524443; // 'CDR5'
  static const int cdrV6 = 0x36524443; // 'CDR6'
  static const int cdrV7 = 0x37524443; // 'CDR7'
  static const int cdrV8 = 0x38524443; // 'CDR8'
  static const int cdrV9 = 0x39524443; // 'CDR9'
  static const int cdrV10 = 0x41524443; // 'CDRA'
  static const int cdrV11 = 0x42524443; // 'CDRB'
  static const int cdrV12 = 0x43524443; // 'CDRC'
  static const int cdrV13 = 0x44524443; // 'CDRD' (X3)

  // Blocos de Geometria e Objetos
  static const int obj = 0x206A626F; // 'obj ' (Objeto genérico)
  static const int crve = 0x65767263; // 'crve' (Curva de Bézier / Caminho)
  static const int outl = 0x6C74756F; // 'outl' (Outline / Traço)
  static const int fild = 0x646C6966; // 'fild' (Fill / Preenchimento)
  static const int text = 0x74786574; // 'text' (Texto Artístico / Parágrafo)
  static const int bmp = 0x20706D62; // 'bmp ' (Imagem Bitmap embutida)

  // Blocos Estruturais
  static const int page = 0x65676170; // 'page' (Página)
  static const int lyr = 0x2072796C; // 'lyr ' (Camada / Layer)
  static const int grp = 0x20707267; // 'grp ' (Grupo de objetos)
  static const int bbox = 0x786F6262; // 'bbox' (Bounding Box)

  /// Converte um inteiro 32-bits lido do binário para uma string ASCII representativa (ex: 'RIFF').
  static String asString(int fourCC) {
    final bytes = [
      fourCC & 0xFF,
      (fourCC >> 8) & 0xFF,
      (fourCC >> 16) & 0xFF,
      (fourCC >> 24) & 0xFF,
    ];
    return String.fromCharCodes(bytes);
  }
}
