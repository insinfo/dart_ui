library;

import '../geometry/offset.dart';
import 'window_events.dart';

/// Base class for all input events reported by the windowing backend.
sealed class PlatformInputEvent extends PlatformWindowEvent {
  const PlatformInputEvent({
    required super.windowId,
    required super.generation,
    required this.timestamp,
  });

  /// Monotonic timestamp of the event, as reported by the OS.
  final Duration timestamp;
}

enum PointerKind { mouse, touch, stylus }

enum PointerButton { primary, secondary, middle, forward, back }

/// Modifier state sampled for a key transition.
enum KeyModifier { shift, control, alt, meta, capsLock, numLock, scrollLock }

/// Physical location of a key when the keyboard exposes left/right variants.
enum KeyLocation { standard, left, right, numpad }

/// The coordinate unit used by a [PointerScrollEvent.scrollDelta].
enum ScrollDeltaUnit { pixels, lines }

/// Base class for pointer input (mouse, touch).
sealed class PointerEvent extends PlatformInputEvent {
  const PointerEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required this.pointerId,
    required this.kind,
    required this.logicalPosition,
  });

  /// A stable identifier for this pointer (e.g., touch finger ID). For mice,
  /// this is typically 0.
  final int pointerId;
  final PointerKind kind;

  /// The position in logical units within the client area of the window.
  final Offset logicalPosition;
}

final class PointerDownEvent extends PointerEvent {
  const PointerDownEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
    required this.button,
    this.clickCount = 1,
  });

  final PointerButton button;

  /// Which press of a multi-click this is, **as the platform counted it**.
  ///
  /// 1 for an ordinary press, 2 when the platform itself decided this press
  /// continues the previous one. It exists because that decision is not a
  /// constant a widget may invent:
  ///
  ///  * Windows registers the class with `CS_DBLCLKS` and answers the second
  ///    press with `WM_LBUTTONDBLCLK`, having matched it against
  ///    `GetDoubleClickTime()` and the `SM_CXDOUBLECLK`/`SM_CYDOUBLECLK`
  ///    rectangle - both of which the user sets in the mouse control panel, and
  ///    both of which are **accessibility settings**: somebody with a tremor or
  ///    reduced dexterity raises the interval precisely because 500 ms is not
  ///    long enough for them. A widget that re-derives the count from a fixed
  ///    interval silently overrides that.
  ///  * macOS reports `NSEvent.clickCount` for the same reason, and X11 reports
  ///    none at all - which is why this defaults to 1 rather than being
  ///    required, and why a consumer must still be able to count for itself.
  ///
  /// It stops at 2 on Windows: there is no `WM_LBUTTONTRIPLECLK`, so a third
  /// press arrives as an ordinary down and a triple click is the consumer's own
  /// arithmetic either way.
  final int clickCount;
}

final class PointerUpEvent extends PointerEvent {
  const PointerUpEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
    required this.button,
  });

  final PointerButton button;
}

final class PointerMoveEvent extends PointerEvent {
  const PointerMoveEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
  });
}

/// Ends pointer interaction without activating it.
///
/// A router synthesizes this when a press started on a target but the release
/// lands outside that target. Native backends may also emit it when the OS
/// revokes capture. Keeping cancellation explicit prevents a later unrelated
/// release from completing an abandoned gesture.
final class PointerCancelEvent extends PointerEvent {
  const PointerCancelEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
  });
}

/// A wheel, trackpad, or other pointer-associated scrolling update.
final class PointerScrollEvent extends PointerEvent {
  const PointerScrollEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
    required this.scrollDelta,
    required this.scrollDeltaUnit,
  });

  /// The requested scroll along the logical x and y axes.
  ///
  /// Positive values move toward increasing coordinates. Consumers must
  /// interpret this value according to [scrollDeltaUnit].
  final Offset scrollDelta;

  /// Whether [scrollDelta] is expressed as logical pixels or discrete lines.
  final ScrollDeltaUnit scrollDeltaUnit;
}

/// A physical key transition.
sealed class KeyEvent extends PlatformInputEvent {
  const KeyEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required this.physicalKey,
    required this.logicalKey,
    this.modifiers = const <KeyModifier>{},
    this.isRepeat = false,
    this.location = KeyLocation.standard,
  });

  /// The OS-specific physical scan code.
  final int physicalKey;

  /// The OS-specific logical virtual key code (ignoring modifiers for now).
  final int logicalKey;

  final Set<KeyModifier> modifiers;

  /// True when the OS reports this transition as keyboard auto-repeat.
  final bool isRepeat;

  final KeyLocation location;
}

final class KeyDownEvent extends KeyEvent {
  const KeyDownEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.physicalKey,
    required super.logicalKey,
    super.modifiers,
    super.isRepeat,
    super.location,
  });
}

final class KeyUpEvent extends KeyEvent {
  const KeyUpEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.physicalKey,
    required super.logicalKey,
    super.modifiers,
    super.isRepeat,
    super.location,
  });
}

/// Text the platform produced from the user's keyboard, already translated.
///
/// **A key is not a character, and a character cannot be derived from a key.**
/// That is the distinction every platform draws and this framework now draws
/// with it - Win32 splits `WM_KEYDOWN` from `WM_CHAR`, X11 splits `KeyPress`
/// from `xkb_state_key_get_utf8`, AppKit splits `keyDown:` from
/// `NSTextInputClient.insertText:` - and the reason is that only the OS knows
/// the answer:
///
///   * the **layout** decides what a key means: the key labelled `;` on a US
///     keyboard is `ç` on a Brazilian ABNT2 one, and there is no table in this
///     repository that could know which is plugged in;
///   * **dead keys and AltGr** mean one character can take two keystrokes and
///     one keystroke can produce no character at all;
///   * **Shift and CapsLock** decide case, so the same key is `a` or `A`;
///   * **NumLock** decides whether the numeric keypad sends digits or
///     navigation, so the *same* virtual key is `1` or `End`;
///   * an **input method** can turn a dozen keystrokes into one ideograph, or
///     into none while it is still composing.
///
/// The historical bug this type exists to end: [KeyEvent.logicalKey] is a
/// virtual-key code, and `String.fromCharCode(logicalKey)` happens to be right
/// for `A`-`Z` because those virtual keys equal their ASCII letters. Everything
/// else it touched was wrong - `VK_NUMPAD1` (0x61) typed `a`, `VK_DOWN` (0x28)
/// typed `(`, and no accented character could ever be typed at all.
///
/// So the two live side by side and neither derives from the other:
///
///   * [KeyEvent] is **hardware**: shortcuts, chords, navigation, key repeat.
///     [KeyEvent.logicalKey] remains correct for exactly that.
///   * [TextInputEvent] is **content**: what the layout produced, as a
///     [String], for insertion into a document.
///
/// A backend that cannot translate text must emit no [TextInputEvent] at all
/// rather than guessing from a key code.
final class TextInputEvent extends PlatformInputEvent {
  TextInputEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required this.text,
  }) {
    if (text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
  }

  /// The characters to insert, in logical order.
  ///
  /// Never empty, never a control character, and never half of a surrogate
  /// pair: those three are the platform layer's job to filter, because a
  /// consumer that had to re-check them would be re-implementing
  /// [TextInputAssembler] at every call site. An astral character - an emoji -
  /// arrives here whole even where the OS delivered it one UTF-16 unit at a
  /// time.
  final String text;

  @override
  String toString() => 'TextInputEvent(${text.runes.map(
        (int rune) =>
            'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
      ).join(' ')})';
}

/// Turns a platform's UTF-16 character stream into [TextInputEvent.text].
///
/// Every backend that reports text one UTF-16 code unit at a time needs the
/// same two rules, and getting either wrong is a user-visible bug, so they live
/// here once instead of once per backend:
///
///  1. **Control characters are not text.** Windows sends `WM_CHAR` for
///     Backspace (0x08), Tab (0x09), Enter (0x0D) and Escape (0x1B), and sends
///     Ctrl+letter as 0x01-0x1A, so Ctrl+A would insert U+0001 into the
///     document. The criterion is Unicode general category `Cc` - U+0000 to
///     U+001F and U+007F to U+009F - which is exactly the set that has no
///     printed form. Those keystrokes are still delivered as [KeyEvent]s,
///     which is where an editor handles them.
///  2. **A surrogate pair is one character.** UTF-16 delivers an astral
///     character - any emoji - as a high surrogate followed by a low one, in
///     two separate messages. Emitting them separately would put half a
///     character into the document, and this repository's `TextEditingValue`
///     rejects an offset that lands between them, so it would raise rather
///     than merely corrupt. The high half is therefore held until its low half
///     arrives.
///
/// An unpaired surrogate is dropped in both directions: a lone low surrogate
/// with nothing held, and a held high surrogate followed by anything other
/// than a low one. Neither is a character, and no completion for them will
/// ever arrive.
final class TextInputAssembler {
  int _highSurrogate = 0;

  /// Whether a high surrogate is waiting for its low half.
  bool get isPending => _highSurrogate != 0;

  /// Accepts one UTF-16 code unit, returning the completed character or null.
  ///
  /// Null means "nothing to report yet or ever": a held high surrogate, a
  /// control character, or an unpaired surrogate.
  String? accept(int codeUnit) {
    final int unit = codeUnit & 0xFFFF;
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      // A second high surrogate abandons the first: two highs in a row cannot
      // be a pair, and keeping the older one would pair it with a low half
      // that belongs to a different character.
      _highSurrogate = unit;
      return null;
    }
    final int high = _highSurrogate;
    _highSurrogate = 0;
    if (unit >= 0xDC00 && unit <= 0xDFFF) {
      if (high == 0) return null;
      return String.fromCharCodes(<int>[high, unit]);
    }
    if (isTextInputControlUnit(unit)) return null;
    return String.fromCharCode(unit);
  }

  /// Forgets a half-delivered character.
  ///
  /// Called when the stream can no longer be trusted to continue - focus left
  /// the window, the window is being destroyed - so that the next character
  /// typed is not fused with the orphan.
  void reset() => _highSurrogate = 0;
}

/// Whether [unit] is a C0 or C1 control, which no backend may report as text.
///
/// See [TextInputAssembler] for why the boundary is drawn here.
bool isTextInputControlUnit(int unit) =>
    unit < 0x20 || (unit >= 0x7F && unit <= 0x9F);
