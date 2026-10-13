/// What the editor's commands need from whoever shows them: dialogs, the
/// size of the view, the window.
library;

import 'package:dart_ui/vector.dart';

/// The part of a command that needs a person or a window.
///
/// A command that can run without asking - `file.save` with a `path`,
/// `file.open` with one - never reaches the host; without one it asks the
/// host to ask. The window implements this; a headless run, a test or an
/// automation client can implement it with no dialogs at all.
abstract interface class EditorHost {
  /// The canvas box, which zooming and fitting are about.
  Size get viewport;

  /// Asks for a drawing to open and opens it.
  void pickAndOpen();

  /// Asks where to write the active drawing as [format] and writes it.
  void pickAndSave(String format);

  /// Closes tab [index], asking first when it has unsaved changes.
  void closeDocument(int index);

  /// Asks to close the editor, as its window's close button does.
  void quit();
}
