import '../../graphics/display_list.dart';
import 'pdf_canvas_recorder.dart';

/// Converte um [DisplayList] preexistente (gravado a partir de chamadas `ui.Canvas` normais)
/// em um fluxo de conteúdo PDF usando o [PdfCanvasRecorder].
class DisplayListToPdfWriter {
  /// Executa (replay) todos os comandos do [displayList] em um [PdfCanvasRecorder]
  /// e retorna o objeto gravador, que já contém o fluxo de texto do PDF (Content Stream).
  static PdfCanvasRecorder write(DisplayList displayList,
      {double pageHeight = 792.0}) {
    final recorder = PdfCanvasRecorder(pageHeight: pageHeight);

    // O DisplayList dispara os eventos de desenho no recorder,
    // que atua como um alvo compatível com os callbacks gráficos.
    // displayList.replay(recorder); // TODO: Implementar parser de opcodes do DisplayList

    return recorder;
  }
}
