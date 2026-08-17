import '../styles/cdr_styles.dart';

/// Catálogo e tabela de paletas de cores padrão e Pantone do CorelDRAW em Puro Dart.
class CdrColorPalette {
  final String name;
  final Map<int, CdrColor> colorsById;

  const CdrColorPalette({
    required this.name,
    required this.colorsById,
  });

  /// Paleta padrão clássica da Corel (Corel Standard Palette).
  static const CdrColorPalette corelStandard = CdrColorPalette(
    name: 'Corel Standard',
    colorsById: {
      0: CdrColor.rgb(255, 255, 255), // Branco
      1: CdrColor.rgb(0, 0, 0), // Preto
      2: CdrColor.rgb(255, 0, 0), // Vermelho
      3: CdrColor.rgb(0, 255, 0), // Verde
      4: CdrColor.rgb(0, 0, 255), // Azul
      5: CdrColor.rgb(255, 255, 0), // Amarelo
      6: CdrColor.rgb(255, 0, 255), // Magenta
      7: CdrColor.rgb(0, 255, 255), // Ciano
      8: CdrColor.rgb(128, 0, 0), // Marrom
      9: CdrColor.rgb(0, 128, 0), // Verde Escuro
      10: CdrColor.rgb(0, 0, 128), // Azul Marinho
      11: CdrColor.rgb(128, 128, 0), // Oliva
      12: CdrColor.rgb(128, 0, 128), // Roxo
      13: CdrColor.rgb(0, 128, 128), // Azul Petróleo
      14: CdrColor.rgb(192, 192, 192), // Cinza Claro
      15: CdrColor.rgb(128, 128, 128), // Cinza Médio
    },
  );

  /// Mapeamento de cores Pantone Spot comuns.
  static const Map<String, CdrColor> pantoneColors = {
    'PANTONE Yellow C': CdrColor.rgb(254, 221, 0),
    'PANTONE Yellow 012 C': CdrColor.rgb(255, 215, 0),
    'PANTONE Orange 021 C': CdrColor.rgb(254, 80, 0),
    'PANTONE Warm Red C': CdrColor.rgb(249, 56, 34),
    'PANTONE Red 032 C': CdrColor.rgb(239, 51, 64),
    'PANTONE Rubine Red C': CdrColor.rgb(206, 0, 88),
    'PANTONE Rhodamine Red C': CdrColor.rgb(225, 0, 117),
    'PANTONE Purple C': CdrColor.rgb(187, 41, 187),
    'PANTONE Violet C': CdrColor.rgb(114, 34, 130),
    'PANTONE Blue 072 C': CdrColor.rgb(16, 6, 159),
    'PANTONE Reflex Blue C': CdrColor.rgb(10, 20, 110),
    'PANTONE Process Blue C': CdrColor.rgb(0, 133, 202),
    'PANTONE Green C': CdrColor.rgb(0, 171, 132),
    'PANTONE Black C': CdrColor.rgb(45, 41, 38),
  };

  /// Resolve uma cor pelo índice da paleta com fallback seguro para preto.
  CdrColor getColor(int id) {
    return colorsById[id] ?? CdrColor.black;
  }

  /// Resolve uma cor Pantone pelo nome.
  static CdrColor getPantoneColor(String name) {
    return pantoneColors[name] ?? CdrColor.black;
  }
}
