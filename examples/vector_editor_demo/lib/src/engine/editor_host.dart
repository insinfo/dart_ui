/// What the editor's commands need from whoever shows them: dialogs, the
/// size of the view, the window.
library;

import 'dart:typed_data';

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

  /// Asks what to find and what to replace it with in the drawing's text,
  /// and replaces it - Edit > Find and Replace.
  void findReplace();
}

/// A host that reaches the system clipboard - the window does; a headless
/// run does not, and Paste Special then offers only what was copied here.
///
/// A port of its own rather than more of [EditorHost], so the hosts that
/// have no clipboard need not pretend to.
abstract interface class EditorClipboardHost {
  /// What the system clipboard holds: any of `image`, `text`.
  Future<Set<String>> clipboardFormats();

  /// The image on the system clipboard as PNG bytes, or null.
  Future<Uint8List?> clipboardImage();

  /// The text on the system clipboard, or null.
  Future<String?> clipboardText();

  /// Puts [objects] on the system clipboard as a picture, so another
  /// application can paste what was copied here.
  Future<void> copyPicture(List<SelectableObject> objects);

  /// Asks which of [formats] to paste, then pastes it - Edit > Paste
  /// Special. `objects` is what this editor copied; the others come from
  /// the system clipboard.
  void choosePasteFormat(List<String> formats);
}
