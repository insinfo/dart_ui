/// Classe base abstrata para todos os tipos de preenchimento vetorial do CorelDRAW.
abstract class CdrFill {
  const CdrFill();
}

/// Preenchimento sólido padrão (Uniform Fill).
class CdrSolidFill extends CdrFill {
  final int colorArgb; // Cor no formato 0xAARRGGBB

  const CdrSolidFill(this.colorArgb);
}

/// Preenchimento de Padrão (Pattern Fill) - Raster ou Vetorial
class CdrPatternFill extends CdrFill {
  final int id;
  const CdrPatternFill(this.id);
}

/// Preenchimento tipo PowerClip (Recorte por Máscara Aninhado)
class CdrPowerClip extends CdrFill {
  final int containerId;
  const CdrPowerClip(this.containerId);
}
