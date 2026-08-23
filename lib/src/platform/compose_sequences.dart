/// Dead keys and Compose sequences, from the X11 Compose tables, in Dart.
///
/// ## Why this exists, and why it is not an input method
///
/// `á` on a Brazilian, Portuguese, French or German keyboard is two keystrokes:
/// the accent key, which produces no character, and then the letter. X11 calls
/// the accent key a **dead key** and spells the pair as a *Compose sequence*:
///
/// ```
/// <dead_acute> <a> : "á"   aacute
/// <Multi_key> <o> <c> : "©"   copyright
/// ```
///
/// Windows does this inside the OS - `WM_DEADCHAR` followed by a composed
/// `WM_CHAR` - so the Win32 backend gets it for free and must not re-implement
/// it. X11 and Wayland do not: `wl_keyboard` and `xcb` deliver *keysyms*, and
/// turning `dead_acute` followed by `a` into `á` is the client's job unless the
/// client is talking to a full input method. That is what this file does.
///
/// **It is not an IME and does not pretend to be.** There is no preedit, no
/// candidate window and no conversion; a pending dead key produces no text at
/// all until it resolves. That is exactly what a dead key is, and it is why
/// this sits beside `text_input.dart` rather than inside it: composition needs
/// a platform contract, and this needs a table.
///
/// ## The table is the platform's, not ours
///
/// The sequences are read from the X11 Compose files that are already on the
/// machine - `~/.XCompose`, then `$XCOMPOSEFILE`, then
/// `/usr/share/X11/locale/<locale>/Compose` - because they are what every other
/// application on that desktop obeys. A table compiled into this package would
/// disagree with the user's own `~/.XCompose` the moment they edited it, and
/// would be wrong for every locale but the one it was built from.
///
/// A machine with no Compose file gets [ComposeTable.empty], and every keysym
/// then passes straight through: no dead keys, and nothing worse than today.
///
/// ## What is deliberately not supported
///
///   * **Modifier predicates** (`<Ctrl> <Alt>` prefixes and the `! Ctrl` syntax
///     of an XKB compose file's conditional sections). Rare, and getting them
///     half right would silently change which sequences fire.
///   * **The trailing keysym name** on a line (`aacute` after the string). It
///     is redundant with the string for insertion purposes and only matters to
///     an application that wants a keysym back rather than text.
///   * **Sequences whose left-hand side names a keysym this file cannot
///     resolve.** They are counted in [ComposeTable.skippedSequences] rather
///     than guessed at, so a diagnostic can say how much of the table was
///     understood instead of leaving a user wondering why one accent works and
///     another does not.
library;

/// What a keysym did when it was fed to a [ComposeEngine].
enum ComposeStatus {
  /// Not part of any sequence. The caller handles the keysym as it would have
  /// without a compose table at all.
  pass,

  /// A prefix of at least one sequence. **No text**, and the keysym must not
  /// be handled as itself: this is the dead key, and inserting the accent on
  /// its own is precisely the bug dead keys exist to avoid.
  pending,

  /// A sequence completed. [ComposeResult.text] is what to insert.
  composed,

  /// The keys so far are not a prefix of anything.
  ///
  /// Distinct from [pass] because the *previous* keystrokes were consumed and
  /// produced nothing: `dead_acute` then `q` is not `q` with an accent and is
  /// not a silent nothing either. X11's own behaviour is to discard the
  /// sequence, which is what a caller should do - and which it can only do if
  /// this is not spelled as [pass].
  invalid,
}

/// The outcome of feeding one keysym to a [ComposeEngine].
final class ComposeResult {
  const ComposeResult._(this.status, this.text);

  static const ComposeResult pass = ComposeResult._(ComposeStatus.pass, null);
  static const ComposeResult pending =
      ComposeResult._(ComposeStatus.pending, null);
  static const ComposeResult invalid =
      ComposeResult._(ComposeStatus.invalid, null);

  factory ComposeResult.composed(String text) =>
      ComposeResult._(ComposeStatus.composed, text);

  final ComposeStatus status;

  /// The text to insert, and only for [ComposeStatus.composed].
  final String? text;

  @override
  String toString() => text == null
      ? 'ComposeResult(${status.name})'
      : 'ComposeResult(composed, "$text")';
}

/// One node of the sequence trie.
final class _ComposeNode {
  final Map<int, _ComposeNode> children = <int, _ComposeNode>{};

  /// The text this node completes, or null when it is only a prefix.
  ///
  /// A node can be both: `<dead_acute> <a>` yields `á` and is also the prefix
  /// of nothing in the standard table, but user tables do define such pairs,
  /// and X11 resolves them by taking the completion as soon as no longer
  /// sequence can match. See [ComposeEngine.accept].
  String? result;
}

/// A parsed set of Compose sequences.
final class ComposeTable {
  ComposeTable._(this._root, this.sequenceCount, this.skippedSequences);

  /// No sequences at all: every keysym passes through.
  ///
  /// The state of a machine with no Compose file, and of Windows, where the OS
  /// composes dead keys before the application ever sees them.
  static final ComposeTable empty = ComposeTable._(_ComposeNode(), 0, 0);

  final _ComposeNode _root;

  /// How many sequences were understood.
  final int sequenceCount;

  /// How many lines named a keysym this file cannot resolve and were dropped.
  ///
  /// Counted rather than ignored: a table where this is most of the file means
  /// the keysym-name coverage is the thing to fix, and a user reporting "the
  /// tilde works but the ogonek does not" has a number to quote.
  final int skippedSequences;

  bool get isEmpty => sequenceCount == 0;

  /// Parses one Compose file.
  ///
  /// [resolveInclude] is called for each `include "..."` directive with the
  /// quoted path exactly as written - `%L`, `%H` and `%S` unexpanded - and
  /// returns that file's contents, or null to skip it. Injected rather than
  /// read here so the parser has no `dart:io` in it and the whole grammar is
  /// testable from a string.
  ///
  /// Includes are followed depth-first and **cycle-guarded**: a
  /// `~/.XCompose` that includes `%L`, which on some distributions includes a
  /// file that includes it back, is a real configuration and must not hang.
  factory ComposeTable.parse(
    String source, {
    String? Function(String path)? resolveInclude,
  }) {
    final root = _ComposeNode();
    var accepted = 0;
    var skipped = 0;
    final visited = <String>{};

    void parseSource(String text, int depth) {
      if (depth > 8) return;
      for (final String rawLine in text.split('\n')) {
        final String line = _stripComment(rawLine).trim();
        if (line.isEmpty) continue;
        if (line.startsWith('include')) {
          final String? path = _quotedArgument(line);
          if (path == null || !visited.add(path)) continue;
          final String? included = resolveInclude?.call(path);
          if (included != null) parseSource(included, depth + 1);
          continue;
        }
        // Conditional sections and modifier predicates: skipped whole, and
        // counted, rather than parsed as though the condition were absent.
        if (line.startsWith('!') || line.startsWith('<Ctrl>')) {
          skipped++;
          continue;
        }
        final int colon = line.indexOf(':');
        if (colon < 0) continue;
        final List<int>? keysyms = _parseKeysyms(line.substring(0, colon));
        if (keysyms == null || keysyms.isEmpty) {
          skipped++;
          continue;
        }
        final String? result = _parseResult(line.substring(colon + 1));
        if (result == null || result.isEmpty) {
          skipped++;
          continue;
        }
        _ComposeNode node = root;
        for (final int keysym in keysyms) {
          node = node.children.putIfAbsent(keysym, _ComposeNode.new);
        }
        node.result = result;
        accepted++;
      }
    }

    parseSource(source, 0);
    return ComposeTable._(root, accepted, skipped);
  }

  static String _stripComment(String line) {
    // A `#` inside the quoted result is not a comment: `<Multi_key> <n> <s> :
    // "#"` is a real line in the standard table.
    var inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final int unit = line.codeUnitAt(i);
      if (unit == 0x22) {
        inQuotes = !inQuotes;
      } else if (unit == 0x5C && inQuotes) {
        i++;
      } else if (unit == 0x23 && !inQuotes) {
        return line.substring(0, i);
      }
    }
    return line;
  }

  static String? _quotedArgument(String line) {
    final int open = line.indexOf('"');
    if (open < 0) return null;
    final int close = line.indexOf('"', open + 1);
    if (close < 0) return null;
    return line.substring(open + 1, close);
  }

  /// `<dead_acute> <a>` to a list of keysyms, or null when one is unknown.
  static List<int>? _parseKeysyms(String text) {
    final keysyms = <int>[];
    var index = 0;
    while (index < text.length) {
      final int open = text.indexOf('<', index);
      if (open < 0) break;
      final int close = text.indexOf('>', open + 1);
      if (close < 0) return null;
      final int keysym = composeKeysymFromName(text.substring(open + 1, close));
      if (keysym == 0) return null;
      keysyms.add(keysym);
      index = close + 1;
    }
    return keysyms.isEmpty ? null : keysyms;
  }

  /// The quoted string after the colon, with the escapes X11 allows.
  static String? _parseResult(String text) {
    final int open = text.indexOf('"');
    if (open < 0) return null;
    final buffer = StringBuffer();
    for (int i = open + 1; i < text.length; i++) {
      final int unit = text.codeUnitAt(i);
      if (unit == 0x22) return buffer.toString();
      if (unit == 0x5C && i + 1 < text.length) {
        i++;
        final int escaped = text.codeUnitAt(i);
        switch (escaped) {
          case 0x6E: // \n
            buffer.write('\n');
          case 0x74: // \t
            buffer.write('\t');
          case 0x72: // \r
            buffer.write('\r');
          case 0x5C: // backslash
            buffer.write(r'\');
          case 0x22: // quote
            buffer.write('"');
          case 0x78 || 0x58: // \xHH, at most two hex digits
            var end = i;
            while (end + 1 < text.length &&
                end - i < 2 &&
                _isHexDigit(text.codeUnitAt(end + 1))) {
              end++;
            }
            final int? value = end == i
                ? null
                : int.tryParse(text.substring(i + 1, end + 1), radix: 16);
            if (value != null) {
              buffer.writeCharCode(value);
              i = end;
            } else {
              buffer.writeCharCode(escaped);
            }
          default:
            // Octal, the last escape X11 allows.
            if (escaped >= 0x30 && escaped <= 0x37) {
              var end = i;
              while (end + 1 < text.length &&
                  end - i < 2 &&
                  text.codeUnitAt(end + 1) >= 0x30 &&
                  text.codeUnitAt(end + 1) <= 0x37) {
                end++;
              }
              final int? value =
                  int.tryParse(text.substring(i, end + 1), radix: 8);
              if (value != null) {
                buffer.writeCharCode(value);
                i = end;
              }
            } else {
              buffer.writeCharCode(escaped);
            }
        }
        continue;
      }
      buffer.writeCharCode(unit);
    }
    // An unterminated string is a malformed line, not an empty result.
    return null;
  }
}

bool _isHexDigit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x46) ||
    (unit >= 0x61 && unit <= 0x66);

/// Runs [ComposeTable] over a stream of keysyms.
///
/// One engine per keyboard focus, because the pending sequence is per-user and
/// must not survive the window losing the keyboard - the second half of a dead
/// key pressed in another application is not this one's to complete.
final class ComposeEngine {
  ComposeEngine(this.table);

  final ComposeTable table;

  final List<int> _pending = <int>[];
  _ComposeNode? _node;

  /// The keysyms consumed so far without producing text. Diagnostics and tests.
  List<int> get pending => List<int>.unmodifiable(_pending);

  /// Whether a sequence is in progress - a dead key is down, in user terms.
  bool get isComposing => _pending.isNotEmpty;

  /// Feeds one keysym.
  ///
  /// **Modifier keysyms must not be fed.** Shift is pressed *during* almost
  /// every compose sequence (`<dead_tilde> <A>` needs it), and feeding it would
  /// break the sequence the user is halfway through. A caller filters them out,
  /// which it has to do anyway to know whether the key produced a character.
  ComposeResult accept(int keysym) {
    final _ComposeNode current = _node ?? table._root;
    final _ComposeNode? next = current.children[keysym];
    if (next == null) {
      if (_pending.isEmpty) return ComposeResult.pass;
      // The sequence died. X11 discards it, and so does this - the alternative,
      // replaying the pending keysyms as text, types the accent character the
      // dead key exists to suppress.
      reset();
      return ComposeResult.invalid;
    }
    _pending.add(keysym);
    final String? result = next.result;
    if (result != null && next.children.isEmpty) {
      reset();
      return ComposeResult.composed(result);
    }
    if (result != null) {
      // Both a completion and a prefix. X11 resolves this greedily *forward* -
      // it waits for a longer match - and so would this, except that waiting
      // means the shorter sequence never fires when the user stops there.
      // Taking the completion now is what xkbcommon's compose state does, and
      // it is the behaviour a user can predict.
      reset();
      return ComposeResult.composed(result);
    }
    _node = next;
    return ComposeResult.pending;
  }

  /// Forgets a half-typed sequence.
  ///
  /// Called when the keyboard leaves the window, for the reason the Win32
  /// backend resets its surrogate assembler on `WM_KILLFOCUS`: the rest of the
  /// sequence is going somewhere else, and fusing it onto the next thing typed
  /// here would produce a character nobody asked for.
  void reset() {
    _pending.clear();
    _node = null;
  }
}

/// Resolves a keysym *name* as it appears between angle brackets in a Compose
/// file.
///
/// Understands, in order: a single ASCII character (`<a>`), `UXXXX` and
/// `U+XXXX`, `0x`-prefixed raw values, and the named table below. Returns 0 -
/// `NoSymbol` - for anything else, which is what makes the caller drop the
/// line rather than build a sequence around a keysym it invented.
int composeKeysymFromName(String name) {
  if (name.isEmpty) return 0;
  if (name.length == 1) {
    final int unit = name.codeUnitAt(0);
    if (unit >= 0x21 && unit <= 0x7e) return unit;
  }
  if (name.length > 1 && (name[0] == 'U' || name[0] == 'u')) {
    final String digits = name.startsWith('U+') || name.startsWith('u+')
        ? name.substring(2)
        : name.substring(1);
    final int? parsed = int.tryParse(digits, radix: 16);
    if (parsed != null && parsed > 0 && parsed <= 0x10ffff) {
      return parsed < 0x100 ? parsed : 0x01000000 + parsed;
    }
  }
  if (name.startsWith('0x') || name.startsWith('0X')) {
    final int? parsed = int.tryParse(name.substring(2), radix: 16);
    if (parsed != null && parsed > 0) return parsed;
  }
  return composeNamedKeysyms[name] ?? 0;
}

/// The keysym names a Compose table's left-hand side actually uses.
///
/// Not all of `keysymdef.h`: the left-hand side of a sequence is a *typed key*,
/// so it is the ASCII block, the dead keys, `Multi_key`, and the Latin-1
/// letters that can themselves start a further sequence. Everything else in the
/// header appears only as a result, and results are given as strings.
const Map<String, int> composeNamedKeysyms = <String, int>{
  // The compose key itself. `Multi_key` is what X11 calls it; a keyboard's
  // Compose key, Right Alt or Menu is mapped onto it by the layout.
  'Multi_key': 0xff20,

  // The space and punctuation names, which a sequence's left-hand side uses
  // constantly - `<Multi_key> <comma> <c>` for `ç`.
  'space': 0x20,
  'exclam': 0x21,
  'quotedbl': 0x22,
  'numbersign': 0x23,
  'dollar': 0x24,
  'percent': 0x25,
  'ampersand': 0x26,
  'apostrophe': 0x27,
  'quoteright': 0x27,
  'parenleft': 0x28,
  'parenright': 0x29,
  'asterisk': 0x2a,
  'plus': 0x2b,
  'comma': 0x2c,
  'minus': 0x2d,
  'period': 0x2e,
  'slash': 0x2f,
  'colon': 0x3a,
  'semicolon': 0x3b,
  'less': 0x3c,
  'equal': 0x3d,
  'greater': 0x3e,
  'question': 0x3f,
  'at': 0x40,
  'bracketleft': 0x5b,
  'backslash': 0x5c,
  'bracketright': 0x5d,
  'asciicircum': 0x5e,
  'underscore': 0x5f,
  'grave': 0x60,
  'quoteleft': 0x60,
  'braceleft': 0x7b,
  'bar': 0x7c,
  'braceright': 0x7d,
  'asciitilde': 0x7e,
  'nobreakspace': 0xa0,

  // The dead keys. This block is the whole reason the file exists: every one
  // of them produces no character on its own and only means something as the
  // first keysym of a sequence.
  'dead_grave': 0xfe50,
  'dead_acute': 0xfe51,
  'dead_circumflex': 0xfe52,
  'dead_tilde': 0xfe53,
  'dead_macron': 0xfe54,
  'dead_breve': 0xfe55,
  'dead_abovedot': 0xfe56,
  'dead_diaeresis': 0xfe57,
  'dead_abovering': 0xfe58,
  'dead_doubleacute': 0xfe59,
  'dead_caron': 0xfe5a,
  'dead_cedilla': 0xfe5b,
  'dead_ogonek': 0xfe5c,
  'dead_iota': 0xfe5d,
  'dead_voiced_sound': 0xfe5e,
  'dead_semivoiced_sound': 0xfe5f,
  'dead_belowdot': 0xfe60,
  'dead_hook': 0xfe61,
  'dead_horn': 0xfe62,
  'dead_stroke': 0xfe63,
  'dead_abovecomma': 0xfe64,
  'dead_abovereversedcomma': 0xfe65,
  'dead_doublegrave': 0xfe66,
  'dead_belowring': 0xfe67,
  'dead_belowmacron': 0xfe68,
  'dead_belowcircumflex': 0xfe69,
  'dead_belowtilde': 0xfe6a,
  'dead_belowbreve': 0xfe6b,
  'dead_belowdiaeresis': 0xfe6c,
  'dead_invertedbreve': 0xfe6d,
  'dead_belowcomma': 0xfe6e,
  'dead_currency': 0xfe6f,
  'dead_greek': 0xfe8c,

  // The Latin-1 letters a further sequence can start from, which is how
  // `<dead_acute> <ccedilla>` reaches `ḉ` in a locale table.
  'agrave': 0xe0,
  'aacute': 0xe1,
  'acircumflex': 0xe2,
  'atilde': 0xe3,
  'adiaeresis': 0xe4,
  'aring': 0xe5,
  'ae': 0xe6,
  'ccedilla': 0xe7,
  'egrave': 0xe8,
  'eacute': 0xe9,
  'ecircumflex': 0xea,
  'ediaeresis': 0xeb,
  'igrave': 0xec,
  'iacute': 0xed,
  'icircumflex': 0xee,
  'idiaeresis': 0xef,
  'ntilde': 0xf1,
  'ograve': 0xf2,
  'oacute': 0xf3,
  'ocircumflex': 0xf4,
  'otilde': 0xf5,
  'odiaeresis': 0xf6,
  'oslash': 0xf8,
  'ugrave': 0xf9,
  'uacute': 0xfa,
  'ucircumflex': 0xfb,
  'udiaeresis': 0xfc,
  'yacute': 0xfd,
  'ydiaeresis': 0xff,
  'Agrave': 0xc0,
  'Aacute': 0xc1,
  'Acircumflex': 0xc2,
  'Atilde': 0xc3,
  'Adiaeresis': 0xc4,
  'Aring': 0xc5,
  'AE': 0xc6,
  'Ccedilla': 0xc7,
  'Egrave': 0xc8,
  'Eacute': 0xc9,
  'Ecircumflex': 0xca,
  'Ediaeresis': 0xcb,
  'Igrave': 0xcc,
  'Iacute': 0xcd,
  'Icircumflex': 0xce,
  'Idiaeresis': 0xcf,
  'Ntilde': 0xd1,
  'Ograve': 0xd2,
  'Oacute': 0xd3,
  'Ocircumflex': 0xd4,
  'Otilde': 0xd5,
  'Odiaeresis': 0xd6,
  'Oslash': 0xd8,
  'Ugrave': 0xd9,
  'Uacute': 0xda,
  'Ucircumflex': 0xdb,
  'Udiaeresis': 0xdc,
  'Yacute': 0xdd,
};
