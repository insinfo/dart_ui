// The filtering algorithm in [FilteringTextInputFormatter] is adapted from
// Flutter's `services/text_formatter.dart`:
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// Rewriting an edit before a field accepts it - Flutter's
/// `TextInputFormatter` family.
///
/// A formatter sees the value before the edit and the value the edit would
/// produce, and returns the value the field takes instead. `TextField` runs
/// its `inputFormatters`, in order, on every edit the **user** makes - a
/// keystroke, a paste, a cut, an input method's commit, a deletion, a
/// screen reader's "set value" - and never on a change the program makes
/// through the controller, which is Flutter's rule too.
///
/// One difference from Flutter is forced by the editing model: a
/// [TextEditingValue] here refuses a selection offset that falls inside a
/// grapheme cluster (see `text_editing.dart`). The formatters below snap the
/// offsets they compute onto cluster boundaries, so they never produce one;
/// a formatter written by an application that builds an offset in the middle
/// of `é` written as two code points gets an [ArgumentError] where Flutter
/// would have taken the value.
library;

import 'dart:math' as math;

import '../text/grapheme.dart';
import 'text_editing.dart';

/// The shape of [TextInputFormatter.withFunction]'s callback.
typedef TextInputFormatFunction = TextEditingValue Function(
  TextEditingValue oldValue,
  TextEditingValue newValue,
);

/// Rewrites a user's edit before the field takes it.
abstract class TextInputFormatter {
  /// For subclasses.
  const TextInputFormatter();

  /// A formatter that runs [formatFunction].
  const factory TextInputFormatter.withFunction(
    TextInputFormatFunction formatFunction,
  ) = _SimpleTextInputFormatter;

  /// The value the field takes when an edit would turn [oldValue] into
  /// [newValue]. Returning [oldValue] refuses the edit; returning [newValue]
  /// accepts it as it is.
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  );
}

final class _SimpleTextInputFormatter extends TextInputFormatter {
  const _SimpleTextInputFormatter(this.formatFunction);

  final TextInputFormatFunction formatFunction;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      formatFunction(oldValue, newValue);
}

/// How a field holds to its `maxLength` - Flutter's `MaxLengthEnforcement`.
enum MaxLengthEnforcement {
  /// Not at all: the text may grow past the limit, and the field's counter
  /// shows it in the error colour.
  none,

  /// Strictly, even while an input method is composing.
  enforced,

  /// Strictly once the input method has committed: a word being composed may
  /// pass the limit and is cut when it is committed.
  truncateAfterCompositionEnds,
}

/// Keeps only what [filterPattern] matches ([FilteringTextInputFormatter.allow])
/// or removes what it matches ([FilteringTextInputFormatter.deny]), putting
/// [replacementString] where text was dropped.
///
/// The selection and the composing region move with the text: a caret after
/// a removed character ends up where that character was.
class FilteringTextInputFormatter extends TextInputFormatter {
  FilteringTextInputFormatter(
    this.filterPattern, {
    required this.allow,
    this.replacementString = '',
  });

  /// Keeps only the text [filterPattern] matches.
  FilteringTextInputFormatter.allow(
    Pattern filterPattern, {
    String replacementString = '',
  }) : this(filterPattern, allow: true, replacementString: replacementString);

  /// Removes the text [filterPattern] matches.
  FilteringTextInputFormatter.deny(
    Pattern filterPattern, {
    String replacementString = '',
  }) : this(filterPattern, allow: false, replacementString: replacementString);

  /// What is kept ([allow]) or removed (not [allow]).
  final Pattern filterPattern;

  /// Whether [filterPattern] names what stays rather than what goes.
  final bool allow;

  /// Put in place of each removed stretch of text. Empty by default.
  final String replacementString;

  /// Removes line breaks: what a single-line field takes.
  static final TextInputFormatter singleLineFormatter =
      FilteringTextInputFormatter.deny('\n');

  /// Keeps only the ASCII digits.
  static final TextInputFormatter digitsOnly =
      FilteringTextInputFormatter.allow(RegExp(r'[0-9]'));

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final _Accumulator state = _Accumulator(newValue);
    int previousEnd = 0;
    for (final Match match in filterPattern.allMatches(newValue.text)) {
      // The stretch between the previous match and this one, then the match.
      // Which of the two is banned depends on [allow].
      _processRegion(allow, previousEnd, match.start, state);
      _processRegion(!allow, match.start, match.end, state);
      previousEnd = match.end;
    }
    _processRegion(allow, previousEnd, newValue.text.length, state);
    return state.finish();
  }

  void _processRegion(
    bool banned,
    int regionStart,
    int regionEnd,
    _Accumulator state,
  ) {
    final String written = banned
        ? (regionStart == regionEnd ? '' : replacementString)
        : state.input.text.substring(regionStart, regionEnd);
    state.buffer.write(written);
    if (written.length == regionEnd - regionStart) return;

    int adjust(int original) {
      final int added =
          original <= regionStart && original < regionEnd ? 0 : written.length;
      final int removed = original.clamp(regionStart, regionEnd) - regionStart;
      return added - removed;
    }

    final TextEditingValue input = state.input;
    state
      ..base += adjust(input.selection.baseOffset)
      ..extent += adjust(input.selection.extentOffset);
    if (input.composing.isValid) {
      state
        ..composingStart += adjust(input.composing.start)
        ..composingEnd += adjust(input.composing.end);
    }
  }
}

/// The output being built by [FilteringTextInputFormatter], with the offsets
/// that move as text is dropped.
final class _Accumulator {
  _Accumulator(this.input)
      : base = input.selection.baseOffset,
        extent = input.selection.extentOffset,
        composingStart = input.composing.start,
        composingEnd = input.composing.end;

  final TextEditingValue input;
  final StringBuffer buffer = StringBuffer();
  int base;
  int extent;
  int composingStart;
  int composingEnd;

  TextEditingValue finish() {
    final String text = buffer.toString();
    int snap(int offset) => TextMotion.snapDown(text, offset);
    final int start = snap(composingStart);
    final int end = TextMotion.snapUp(text, composingEnd.clamp(0, text.length));
    return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: snap(base),
        extentOffset: snap(extent),
        affinity: input.selection.affinity,
      ),
      composing: input.composing.isValid && start < end
          ? TextRange(start, end)
          : TextRange.empty,
    );
  }
}

/// Caps the text at [maxLength] **characters** - grapheme clusters, what a
/// user counts, so `👨‍👩‍👧` is one - as Flutter's
/// `LengthLimitingTextInputFormatter` does.
class LengthLimitingTextInputFormatter extends TextInputFormatter {
  /// A null or -1 [maxLength] means no limit.
  LengthLimitingTextInputFormatter(this.maxLength, {this.maxLengthEnforcement})
      : assert(maxLength == null || maxLength == -1 || maxLength > 0) {
    final int? limit = maxLength;
    if (limit != null && limit != -1 && limit <= 0) {
      throw ArgumentError.value(
        limit,
        'maxLength',
        'must be positive, or null or -1 for no limit',
      );
    }
  }

  /// The most characters the text may hold; null or -1 for no limit.
  final int? maxLength;

  /// How the limit is held to; null is [getDefaultMaxLengthEnforcement].
  final MaxLengthEnforcement? maxLengthEnforcement;

  /// The enforcement a field uses when it names none.
  ///
  /// [MaxLengthEnforcement.truncateAfterCompositionEnds] everywhere: Flutter
  /// picks `enforced` on Windows and Android, and the two differ only while
  /// an input method is composing, where cutting a word half-way through its
  /// conversion is the worse of the two. The [platform] argument Flutter
  /// takes does not exist here.
  static MaxLengthEnforcement getDefaultMaxLengthEnforcement() =>
      MaxLengthEnforcement.truncateAfterCompositionEnds;

  /// [value] cut to its first [maxLength] characters, with the selection and
  /// the composing region cut with it.
  static TextEditingValue truncate(TextEditingValue value, int maxLength) {
    final String text = value.text;
    int cut = 0;
    for (int i = 0; i < maxLength && cut < text.length; i++) {
      cut = GraphemeBreaks.next(text, cut);
    }
    final String truncated = text.substring(0, cut);
    final TextRange composing = value.composing;
    final int composingEnd = math.min(composing.end, truncated.length);
    return TextEditingValue(
      text: truncated,
      selection: value.selection.copyWith(
        baseOffset: math.min(value.selection.baseOffset, truncated.length),
        extentOffset: math.min(value.selection.extentOffset, truncated.length),
      ),
      composing: composing.isValid && composing.start < composingEnd
          ? TextRange(composing.start, composingEnd)
          : TextRange.empty,
    );
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final int? limit = maxLength;
    if (limit == null ||
        limit == -1 ||
        characterCount(newValue.text) <= limit) {
      return newValue;
    }
    switch (maxLengthEnforcement ?? getDefaultMaxLengthEnforcement()) {
      case MaxLengthEnforcement.none:
        return newValue;
      case MaxLengthEnforcement.enforced:
        // Already full, and the user typed more over a caret: refused whole,
        // rather than accepted and cut, which would drop the character at the
        // end of the text instead of the one just typed.
        if (characterCount(oldValue.text) == limit &&
            oldValue.selection.isCollapsed) {
          return oldValue;
        }
        return truncate(newValue, limit);
      case MaxLengthEnforcement.truncateAfterCompositionEnds:
        if (characterCount(oldValue.text) == limit &&
            !oldValue.composing.isValid) {
          return oldValue;
        }
        if (newValue.composing.isValid) return newValue;
        return truncate(newValue, limit);
    }
  }

  /// How many characters - grapheme clusters - [text] holds.
  static int characterCount(String text) {
    int count = 0;
    for (int at = 0; at < text.length; at = GraphemeBreaks.next(text, at)) {
      count++;
    }
    return count;
  }
}
