/// Turning what the DOM said into what `lib/src/platform/input_events.dart`
/// promises, with no `package:web` anywhere in sight.
///
/// ## Why this file has no DOM types in it
///
/// Every function here takes the *fields* of a DOM event - `key`, `code`,
/// `keyCode`, `button`, `deltaMode` - as plain Dart values, and returns the
/// framework's own vocabulary. Not one signature mentions `KeyboardEvent`.
///
/// That is deliberate, and the reason is the bug this file exists to not
/// repeat. The rules below are the whole of the web backend's input
/// correctness: which DOM property may become text, which may not, and what a
/// numeric keypad does when NumLock is off. Those rules are worth a test each,
/// and a test that needs a browser to run is a test that does not run in CI -
/// this repository's CI has neither Chrome nor a GPU. Keeping the rules in
/// pure Dart means `dart test` on a Linux container exercises them, on the VM,
/// with no `@TestOn('browser')` and nothing skipped.
///
/// `web_window.dart` is the thin half that reads the DOM properties and calls
/// in here. It is the part a browser is genuinely required for, and it is kept
/// as small as possible for that reason.
///
/// ## The rule that decides everything: a key is not a character
///
/// `input_events.dart` states it at length for Win32, X11 and AppKit, and the
/// web draws exactly the same line - it just draws it with different names:
///
///   * **`KeyboardEvent.code`** is *hardware*: `KeyA` is the key in the
///     position a US keyboard labels `A`, whatever the layout has mapped it
///     to. `Numpad1` is the numeric keypad's `1` key, always.
///   * **`KeyboardEvent.keyCode`** is the legacy virtual-key code. On Chrome
///     and Edge for Windows it is literally the Win32 `VK_*` value, which is
///     why it is what this backend reports as [KeyEvent.logicalKey]: a
///     shortcut table written against Win32 keeps working unchanged.
///   * **`KeyboardEvent.key`** is *what the layout produced*: `a`, `A`, `ç`,
///     `1`, or a **name** like `ArrowDown`, `Enter`, `Dead`, `Process`.
///   * **`InputEvent.data` on `beforeinput`** is *content*: the text an input
///     method, a dead-key sequence or an ordinary keystroke committed.
///
/// The historical bug, restated for this platform. `VK_NUMPAD1` is 0x61 and
/// `String.fromCharCode(0x61)` is `a`, so a backend that derived text from the
/// virtual key typed `a` when the user pressed the keypad's `1`. **On the web
/// that bug is available verbatim**: `KeyboardEvent.keyCode` for `Numpad1` is
/// also 97, and `String.fromCharCode(97)` is also `a`. Nothing about moving to
/// a browser fixes it, and [webKeyboardTextFromKey] is the function that
/// refuses to do it - it reads `key`, never `keyCode`, and `key` for that
/// keystroke is `1` with NumLock on and `End` with it off, which is the answer
/// only the platform can give.
///
/// So the split is:
///
///   * [webKeyEventFrom] builds the [KeyEvent] - `code` for the physical key,
///     `keyCode` for the logical one, and no text of any kind.
///   * [webTextFromBeforeInput] builds the [TextInputEvent] from `beforeinput`,
///     which is the only source that survives an IME.
///   * [webKeyboardTextFromKey] is the fallback for a page with no editable
///     element focused, and it is deliberately conservative: one grapheme, no
///     control characters, no Ctrl/Meta chord.
library;

import '../../geometry/offset.dart';
import '../../platform/input_events.dart';
// `NativeWindowId` is declared here, not in `input_events.dart`, and that file
// imports it without re-exporting it - so naming the type in a signature needs
// this import even though every event class already carries one.
import '../../platform/window_events.dart';

// ---------------------------------------------------------------------------
// Keyboard: the hardware half
// ---------------------------------------------------------------------------

/// `KeyboardEvent.location` values, from the UI Events specification.
const int kDomKeyLocationStandard = 0;
const int kDomKeyLocationLeft = 1;
const int kDomKeyLocationRight = 2;
const int kDomKeyLocationNumpad = 3;

/// The [KeyLocation] a DOM `location` names.
///
/// Anything outside the four the specification defines becomes
/// [KeyLocation.standard] rather than throwing: a browser that invents a fifth
/// value must not be able to take a keystroke down with it.
KeyLocation webKeyLocation(int domLocation) => switch (domLocation) {
      kDomKeyLocationLeft => KeyLocation.left,
      kDomKeyLocationRight => KeyLocation.right,
      kDomKeyLocationNumpad => KeyLocation.numpad,
      _ => KeyLocation.standard,
    };

/// The modifier set a DOM keyboard or mouse event reports.
///
/// The four booleans are properties on the event; the three lock states come
/// from `getModifierState`, which is why they are passed separately - a caller
/// that cannot ask (a synthesised event, a test) passes false and the set is
/// simply smaller rather than wrong.
///
/// [KeyModifier.numLock] in particular is *not* decoration here. It is the
/// state that decides whether the keypad sends digits or navigation, and a
/// consumer that wants to know why `Numpad1` produced no text can read it.
Set<KeyModifier> webKeyModifiers({
  required bool shift,
  required bool control,
  required bool alt,
  required bool meta,
  bool capsLock = false,
  bool numLock = false,
  bool scrollLock = false,
}) =>
    <KeyModifier>{
      if (shift) KeyModifier.shift,
      if (control) KeyModifier.control,
      if (alt) KeyModifier.alt,
      if (meta) KeyModifier.meta,
      if (capsLock) KeyModifier.capsLock,
      if (numLock) KeyModifier.numLock,
      if (scrollLock) KeyModifier.scrollLock,
    };

/// The USB HID usage id a `KeyboardEvent.code` string names, or 0.
///
/// ## Why a table and not a hash of the string
///
/// [KeyEvent.physicalKey] is documented as "the OS-specific physical scan
/// code", and the web's honest answer to that is the HID usage - the UI Events
/// `code` specification is *written* as a mapping from HID usages to these
/// strings, so this table is that mapping read backwards rather than a
/// convention invented here. It means `KeyA` is 0x04 on every browser and
/// every operating system, which is the layout-independent identity a
/// key-remapping consumer needs.
///
/// Hashing the string would also produce a stable integer, and would be
/// worthless: two builds could not agree on it, nothing could look one up in a
/// HID table, and a keystroke's physical identity would be an implementation
/// detail of this file's hash function.
///
/// Unknown codes - a browser extension's synthetic key, `Unidentified`, a
/// vendor key not in the specification - answer 0. Zero is not a HID usage, so
/// a consumer can tell "this key has no physical identity here" from any real
/// one, which is better than a collision with a key the user does have.
int webPhysicalKeyFromCode(String code) => _hidUsageByCode[code] ?? 0;

/// `code` -> USB HID usage, for the keys a standard keyboard has.
///
/// Covers the alphanumeric block, the function row, the navigation cluster,
/// the numeric keypad and the modifiers. Deliberately not exhaustive over the
/// specification's media and browser keys: those do not reach a window as
/// ordinary key events on any of the platforms this framework supports, and a
/// table that pretended otherwise would be untested data.
const Map<String, int> _hidUsageByCode = <String, int>{
  'KeyA': 0x04,
  'KeyB': 0x05,
  'KeyC': 0x06,
  'KeyD': 0x07,
  'KeyE': 0x08,
  'KeyF': 0x09,
  'KeyG': 0x0A,
  'KeyH': 0x0B,
  'KeyI': 0x0C,
  'KeyJ': 0x0D,
  'KeyK': 0x0E,
  'KeyL': 0x0F,
  'KeyM': 0x10,
  'KeyN': 0x11,
  'KeyO': 0x12,
  'KeyP': 0x13,
  'KeyQ': 0x14,
  'KeyR': 0x15,
  'KeyS': 0x16,
  'KeyT': 0x17,
  'KeyU': 0x18,
  'KeyV': 0x19,
  'KeyW': 0x1A,
  'KeyX': 0x1B,
  'KeyY': 0x1C,
  'KeyZ': 0x1D,
  'Digit1': 0x1E,
  'Digit2': 0x1F,
  'Digit3': 0x20,
  'Digit4': 0x21,
  'Digit5': 0x22,
  'Digit6': 0x23,
  'Digit7': 0x24,
  'Digit8': 0x25,
  'Digit9': 0x26,
  'Digit0': 0x27,
  'Enter': 0x28,
  'Escape': 0x29,
  'Backspace': 0x2A,
  'Tab': 0x2B,
  'Space': 0x2C,
  'Minus': 0x2D,
  'Equal': 0x2E,
  'BracketLeft': 0x2F,
  'BracketRight': 0x30,
  'Backslash': 0x31,
  'Semicolon': 0x33,
  'Quote': 0x34,
  'Backquote': 0x35,
  'Comma': 0x36,
  'Period': 0x37,
  'Slash': 0x38,
  'CapsLock': 0x39,
  'F1': 0x3A,
  'F2': 0x3B,
  'F3': 0x3C,
  'F4': 0x3D,
  'F5': 0x3E,
  'F6': 0x3F,
  'F7': 0x40,
  'F8': 0x41,
  'F9': 0x42,
  'F10': 0x43,
  'F11': 0x44,
  'F12': 0x45,
  'PrintScreen': 0x46,
  'ScrollLock': 0x47,
  'Pause': 0x48,
  'Insert': 0x49,
  'Home': 0x4A,
  'PageUp': 0x4B,
  'Delete': 0x4C,
  'End': 0x4D,
  'PageDown': 0x4E,
  'ArrowRight': 0x4F,
  'ArrowLeft': 0x50,
  'ArrowDown': 0x51,
  'ArrowUp': 0x52,
  'NumLock': 0x53,
  'NumpadDivide': 0x54,
  'NumpadMultiply': 0x55,
  'NumpadSubtract': 0x56,
  'NumpadAdd': 0x57,
  'NumpadEnter': 0x58,
  'Numpad1': 0x59,
  'Numpad2': 0x5A,
  'Numpad3': 0x5B,
  'Numpad4': 0x5C,
  'Numpad5': 0x5D,
  'Numpad6': 0x5E,
  'Numpad7': 0x5F,
  'Numpad8': 0x60,
  'Numpad9': 0x61,
  'Numpad0': 0x62,
  'NumpadDecimal': 0x63,
  'IntlBackslash': 0x64,
  'ContextMenu': 0x65,
  'NumpadEqual': 0x67,
  'IntlRo': 0x87,
  'IntlYen': 0x89,
  'ControlLeft': 0xE0,
  'ShiftLeft': 0xE1,
  'AltLeft': 0xE2,
  'MetaLeft': 0xE3,
  'ControlRight': 0xE4,
  'ShiftRight': 0xE5,
  'AltRight': 0xE6,
  'MetaRight': 0xE7,
};

/// The physical `code` strings this backend can name, for a diagnostic.
Iterable<String> get webKnownKeyCodes => _hidUsageByCode.keys;

/// Builds the [KeyDownEvent] or [KeyUpEvent] a DOM key transition is.
///
/// [isDown] picks the class. Everything else is copied straight across, and
/// **no text is derived here at all** - that is the whole point of the split,
/// and a caller that wants characters calls [webTextFromBeforeInput] or
/// [webKeyboardTextFromKey] instead.
KeyEvent webKeyEventFrom({
  required bool isDown,
  required NativeWindowId windowId,
  required int generation,
  required Duration timestamp,
  required String code,
  required int keyCode,
  required int domLocation,
  required Set<KeyModifier> modifiers,
  bool isRepeat = false,
}) {
  final int physical = webPhysicalKeyFromCode(code);
  final KeyLocation location = webKeyLocation(domLocation);
  if (isDown) {
    return KeyDownEvent(
      windowId: windowId,
      generation: generation,
      timestamp: timestamp,
      physicalKey: physical,
      logicalKey: keyCode,
      modifiers: modifiers,
      isRepeat: isRepeat,
      location: location,
    );
  }
  return KeyUpEvent(
    windowId: windowId,
    generation: generation,
    timestamp: timestamp,
    physicalKey: physical,
    logicalKey: keyCode,
    modifiers: modifiers,
    // A key-up is never a repeat: auto-repeat produces repeated key-downs and
    // one release. Reporting the flag the DOM happens to carry would say a
    // release repeated, which is not a thing.
    location: location,
  );
}

// ---------------------------------------------------------------------------
// Keyboard: the text half
// ---------------------------------------------------------------------------

/// `InputEvent.inputType` values that insert literal text.
///
/// `insertText` is an ordinary keystroke or a paste of plain text.
/// `insertCompositionText` is an input method's in-progress composition, and
/// `insertFromComposition` its commit; both carry the characters in `data`.
/// `insertReplacementText` is what a spell-check correction or an
/// autocompletion sends.
///
/// Everything else - `deleteContentBackward`, `insertLineBreak`,
/// `historyUndo`, `formatBold` - is an *edit command*, not content, and is
/// deliberately absent: those are keystrokes the [KeyEvent] stream already
/// carries, and turning them into text would insert a character where the user
/// asked for a deletion.
const Set<String> kWebTextInsertingInputTypes = <String>{
  'insertText',
  'insertCompositionText',
  'insertFromComposition',
  'insertReplacementText',
};

/// The text a `beforeinput` event committed, or null when it committed none.
///
/// **This is the primary text source, and the only one that is correct in
/// general.** It is the browser's own answer, after the layout, the dead-key
/// state machine and any input method have all had their say, which is exactly
/// the list of things `input_events.dart` says no table in this repository
/// could know.
///
/// Null when the edit was a command rather than an insertion, when `data` was
/// absent (a paste of rich content reports `dataTransfer` instead), or when
/// the assembled result would be empty. A caller must not fall back to a key
/// code on null - null means "this event inserted nothing", which is a
/// complete answer.
String? webTextFromBeforeInput({
  required String inputType,
  required String? data,
}) {
  if (!kWebTextInsertingInputTypes.contains(inputType)) return null;
  if (data == null || data.isEmpty) return null;
  return sanitiseWebTextInput(data);
}

/// The text an unfocused page can still get out of a `keydown`, or null.
///
/// ## When this is used, and why it is not the primary path
///
/// `beforeinput` only fires at an editable element. An application that is
/// drawing its own text field into a canvas has no such element unless it
/// deliberately keeps a hidden one focused, and until the user clicks into
/// that field there is nothing to fire on. This is the fallback for that
/// window of time, and for a page that never wires one up at all.
///
/// ## What it will and will not accept
///
/// `KeyboardEvent.key` is either **one character** - `a`, `A`, `ç`, `1`, `€`,
/// an emoji from a compose key - or a **name**: `ArrowDown`, `Enter`, `F5`,
/// `Shift`, `Dead`, `Process`, `Unidentified`. The two are told apart by
/// length in *runes*, not in code units, so an astral character survives: it
/// is one rune and two UTF-16 units, and testing `key.length == 1` would
/// reject exactly the emoji this framework's own [TextInputAssembler] exists
/// to keep whole.
///
/// Refused, each for its own reason:
///
///   * **a named key** (more than one rune), because `Enter` is not the word
///     "Enter" typed into the document;
///   * **a control character**, because U+000D is what `Enter`'s `key` would
///     be if a browser reported it that way, and `input_events.dart` forbids
///     controls in [TextInputEvent.text] outright;
///   * **Ctrl or Meta held**, because Ctrl+S is a command. Alt is *not* in
///     that list on purpose: AltGr is reported as Ctrl+Alt on Windows and is
///     how a Brazilian ABNT2 keyboard types `²`, so refusing on Alt alone
///     would make a whole row of characters untypeable. Ctrl alone still
///     refuses, which is the correct answer for a true Ctrl chord;
///   * **`Dead` and `Process`**, the two names that mean "an input method or a
///     dead-key sequence is mid-flight". The character is coming later,
///     through `beforeinput`, and taking the name here would type the letters
///     `D`, `e`, `a`, `d`... except that the rune rule already refuses them.
///     They are named anyway because reading this function should not require
///     deducing it.
String? webKeyboardTextFromKey({
  required String key,
  required bool control,
  required bool meta,
}) {
  if (control || meta) return null;
  if (key.isEmpty) return null;
  // One rune, not one code unit: an astral character is two UTF-16 units and
  // must still be accepted whole.
  final Iterator<int> runes = key.runes.iterator;
  if (!runes.moveNext()) return null;
  final int first = runes.current;
  if (runes.moveNext()) return null;
  if (isTextInputControlUnit(first)) return null;
  return String.fromCharCode(first);
}

/// Drops what [TextInputEvent] refuses to carry, keeping astral pairs whole.
///
/// `beforeinput` hands over a whole string rather than one code unit at a
/// time, so [TextInputAssembler] - which exists for the UTF-16 drip Win32 and
/// X11 deliver - is not the right tool. The two rules it enforces still are:
/// no C0/C1 control characters, and no half of a surrogate pair. This applies
/// them over a string.
///
/// Returns null when nothing survives, because [TextInputEvent] rejects an
/// empty string in its constructor: a backend that passed one through would
/// turn a paste of a single newline into a thrown `ArgumentError` in the frame
/// loop.
String? sanitiseWebTextInput(String text) {
  final StringBuffer kept = StringBuffer();
  for (final int rune in text.runes) {
    // Runes are already decoded pairs, so an unpaired surrogate is the only
    // way half a character can appear here, and it is dropped.
    if (rune >= 0xD800 && rune <= 0xDFFF) continue;
    if (isTextInputControlUnit(rune)) continue;
    kept.writeCharCode(rune);
  }
  final String result = kept.toString();
  return result.isEmpty ? null : result;
}

// ---------------------------------------------------------------------------
// Pointer
// ---------------------------------------------------------------------------

/// The [PointerKind] a `PointerEvent.pointerType` string names.
///
/// The specification defines exactly `mouse`, `pen` and `touch`, and leaves
/// the door open for a user agent to send its own. An unknown one becomes
/// [PointerKind.mouse]: it is the kind with the fewest assumptions attached -
/// no pressure, no contact area - so a device this backend has never heard of
/// behaves like a mouse rather than being dropped.
PointerKind webPointerKind(String pointerType) => switch (pointerType) {
      'touch' => PointerKind.touch,
      'pen' => PointerKind.stylus,
      _ => PointerKind.mouse,
    };

/// The [PointerButton] a `MouseEvent.button` index names, or null.
///
/// The DOM numbering is fixed by the specification and is *not* the same order
/// as [PointerButton] declares its members, which is why this is a switch and
/// not a cast: `button == 1` is the middle button and `button == 2` is the
/// secondary one, while [PointerButton.secondary] is index 1 in the enum.
/// Casting the integer would swap right-click and middle-click, which reads as
/// a context menu that opens on the wrong button.
///
/// Null for anything above 4, and for `-1`, which `pointermove` reports to
/// mean "no button changed state".
PointerButton? webPointerButton(int domButton) => switch (domButton) {
      0 => PointerButton.primary,
      1 => PointerButton.middle,
      2 => PointerButton.secondary,
      3 => PointerButton.back,
      4 => PointerButton.forward,
      _ => null,
    };

/// `WheelEvent.deltaMode` values, from the UI Events specification.
const int kDomDeltaPixel = 0;
const int kDomDeltaLine = 1;
const int kDomDeltaPage = 2;

/// Lines a `DOM_DELTA_PAGE` wheel notch stands for.
///
/// The specification gives no number, because a page is however much of the
/// document is visible - which is a question for the scrollable, not for the
/// backend. [PointerScrollEvent] has no `pages` unit, so the choice is between
/// inventing one, dropping the event, or converting. This converts, at the
/// figure a page-up key conventionally means on a text view, and the constant
/// is named so the arbitrariness is visible rather than buried in a
/// multiplication.
const double kWebLinesPerPage = 16;

/// The scroll a DOM `wheel` event asks for, in this framework's convention.
///
/// ## The sign is already right, and that is worth stating
///
/// `WheelEvent.deltaY` is **positive when scrolling down** and `deltaX`
/// positive when scrolling right, which is precisely "toward increasing
/// coordinates" - the contract [PointerScrollEvent.scrollDelta] states. So
/// nothing is negated here.
///
/// That is the opposite of Win32, where `WHEEL_DELTA` is positive rolling
/// *away* from the user and `win32_window.dart` negates the vertical word to
/// compensate. Both files agree on the destination; they start from different
/// places. A reader who copies the Win32 negation into this backend inverts
/// the wheel, which is a bug users report as "scrolling is backwards" and
/// nothing in a golden test would ever catch.
///
/// ## Units
///
/// `DOM_DELTA_PIXEL` is reported as [ScrollDeltaUnit.pixels] - Chrome's
/// default for a mouse wheel is pixels, roughly 100 per notch, and a trackpad
/// sends small pixel values continuously, which is exactly what that unit is
/// for. `DOM_DELTA_LINE` is Firefox's default and maps to
/// [ScrollDeltaUnit.lines] unchanged. `DOM_DELTA_PAGE` becomes lines via
/// [kWebLinesPerPage].
({Offset delta, ScrollDeltaUnit unit}) webScrollDelta({
  required double deltaX,
  required double deltaY,
  required int deltaMode,
}) =>
    switch (deltaMode) {
      kDomDeltaLine => (
          delta: Offset(deltaX, deltaY),
          unit: ScrollDeltaUnit.lines,
        ),
      kDomDeltaPage => (
          delta: Offset(deltaX * kWebLinesPerPage, deltaY * kWebLinesPerPage),
          unit: ScrollDeltaUnit.lines,
        ),
      _ => (
          delta: Offset(deltaX, deltaY),
          unit: ScrollDeltaUnit.pixels,
        ),
    };

/// The multi-click count a DOM event reports, clamped to what the contract
/// promises.
///
/// `MouseEvent.detail` is the browser's own click counter, incremented while
/// presses fall inside the platform's double-click time and distance - the
/// same accessibility settings `PointerDownEvent.clickCount` documents for
/// Windows, honoured by the browser rather than re-derived here.
///
/// Clamped to at least 1 because `detail` is 0 on a `pointerdown` synthesised
/// by a script or dispatched by a driver, and a click count of zero would say
/// a press that did happen did not.
int webClickCount(int detail) => detail < 1 ? 1 : detail;
