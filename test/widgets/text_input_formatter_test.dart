/// Flutter's input formatters, input types and actions, and the Flutter
/// names on the editing model and the controller.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

TextEditingValue _v(String text, [int? caret]) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(caret ?? text.length),
    );

void main() {
  group('FilteringTextInputFormatter', () {
    test('digitsOnly keeps the digits and moves the caret with the text', () {
      final TextEditingValue out = FilteringTextInputFormatter.digitsOnly
          .formatEditUpdate(_v('12'), _v('12a3', 3));
      expect(out.text, '123');
      expect(out.selection, const TextSelection.collapsed(2),
          reason: 'the caret was after "a", which is gone');
    });

    test('deny removes matches and writes the replacement', () {
      final TextEditingValue out = FilteringTextInputFormatter.deny(
              RegExp(r'\s+'),
              replacementString: '-')
          .formatEditUpdate(_v(''), _v('a b  c'));
      expect(out.text, 'a-b-c');
      expect(out.selection.extentOffset, 5);
    });

    test('allow with a replacement keeps the matches only', () {
      final TextEditingValue out = FilteringTextInputFormatter.allow(
              RegExp('[a-z]'),
              replacementString: '*')
          .formatEditUpdate(_v(''), _v('ab12cd'));
      expect(out.text, 'ab*cd');
    });

    test('singleLineFormatter drops line breaks', () {
      expect(
        FilteringTextInputFormatter.singleLineFormatter
            .formatEditUpdate(_v(''), _v('a\nb'))
            .text,
        'ab',
      );
    });

    test('a selection survives as a selection, ends moved', () {
      final TextEditingValue out =
          FilteringTextInputFormatter.digitsOnly.formatEditUpdate(
        _v(''),
        TextEditingValue(
          text: 'x1y2z3',
          selection: const TextSelection(baseOffset: 1, extentOffset: 5),
        ),
      );
      expect(out.text, '123');
      expect(out.selection.baseOffset, 0);
      expect(out.selection.extentOffset, 2);
    });
  });

  group('LengthLimitingTextInputFormatter', () {
    test('counts grapheme clusters, not code units', () {
      final LengthLimitingTextInputFormatter limit =
          LengthLimitingTextInputFormatter(2);
      final TextEditingValue out =
          limit.formatEditUpdate(_v(''), _v('👨‍👩‍👧é'));
      expect(out.text, '👨‍👩‍👧é', reason: 'two characters');
      expect(
        LengthLimitingTextInputFormatter.characterCount('👨‍👩‍👧é'),
        2,
      );
    });

    test('a full field refuses another character over a caret', () {
      final LengthLimitingTextInputFormatter limit =
          LengthLimitingTextInputFormatter(3,
              maxLengthEnforcement: MaxLengthEnforcement.enforced);
      final TextEditingValue old = _v('abc');
      expect(limit.formatEditUpdate(old, _v('abcd')), old);
    });

    test('a paste past the limit is truncated', () {
      final LengthLimitingTextInputFormatter limit =
          LengthLimitingTextInputFormatter(4);
      final TextEditingValue out =
          limit.formatEditUpdate(_v('a'), _v('abcdef'));
      expect(out.text, 'abcd');
      expect(out.selection, const TextSelection.collapsed(4));
    });

    test('composing text may pass the limit until it is committed', () {
      final LengthLimitingTextInputFormatter limit =
          LengthLimitingTextInputFormatter(3);
      final TextEditingValue composing = TextEditingValue(
        text: 'abcd',
        selection: const TextSelection.collapsed(4),
        composing: const TextRange(2, 4),
      );
      expect(limit.formatEditUpdate(_v('ab'), composing), composing);
    });

    test('none lets the text grow', () {
      final LengthLimitingTextInputFormatter limit =
          LengthLimitingTextInputFormatter(2,
              maxLengthEnforcement: MaxLengthEnforcement.none);
      expect(limit.formatEditUpdate(_v('ab'), _v('abc')).text, 'abc');
    });

    test('a non-positive limit is an ArgumentError, not a crash later', () {
      expect(() => LengthLimitingTextInputFormatter(0), throwsA(isA<Error>()));
    });
  });

  test('TextInputFormatter.withFunction runs the function', () {
    final TextInputFormatter upper = TextInputFormatter.withFunction(
      (TextEditingValue oldValue, TextEditingValue newValue) =>
          newValue.copyWith(text: newValue.text.toUpperCase()),
    );
    expect(upper.formatEditUpdate(_v(''), _v('abc')).text, 'ABC');
  });

  group('TextInputType', () {
    test('has Flutter\'s values and maps onto the input-method purpose', () {
      expect(TextInputType.values, hasLength(13));
      expect(TextInputType.number, const TextInputType.numberWithOptions());
      expect(TextInputType.number.imeContentPurpose, ImeContentPurpose.digits);
      expect(
        const TextInputType.numberWithOptions(decimal: true).imeContentPurpose,
        ImeContentPurpose.number,
      );
      expect(TextInputType.emailAddress.imeContentPurpose,
          ImeContentPurpose.email);
      expect(TextInputType.text.signed, isNull);
      expect(TextInputType.url.toJson()['name'], 'TextInputType.url');
    });

    test('TextCapitalization is a hint', () {
      expect(TextCapitalization.words.imeContentHint, ImeContentHint.titlecase);
      expect(TextCapitalization.none.imeContentHint, isNull);
    });
  });

  group('Flutter names on the editing model', () {
    test('TextRange.collapsed, textBefore and textAfter', () {
      const TextRange range = TextRange(1, 3);
      expect(range.textBefore('abcde'), 'a');
      expect(range.textInside('abcde'), 'bc');
      expect(range.textAfter('abcde'), 'de');
      expect(const TextRange.collapsed(2).isCollapsed, isTrue);
    });

    test('TextSelection.fromPosition, base and isValid', () {
      final TextSelection s = TextSelection.fromPosition(
          const TextPosition(2, affinity: TextAffinity.upstream));
      expect(s.isCollapsed, isTrue);
      expect(s.affinity, TextAffinity.upstream);
      expect(s.base.offset, 2);
      expect(const TextSelection.collapsed(-1).isValid, isFalse);
    });
  });

  group('TextEditingController with Flutter\'s API', () {
    test('text, selection, clear and fromValue', () {
      final TextEditingController controller =
          TextEditingController.fromValue(TextEditingValue(
        text: 'hello',
        selection: const TextSelection(baseOffset: 1, extentOffset: 3),
      ));
      expect(controller.text, 'hello');
      expect(controller.selection,
          const TextSelection(baseOffset: 1, extentOffset: 3));
      controller.text = 'hey';
      expect(controller.value, 'hey');
      controller.selection = const TextSelection.collapsed(1);
      expect(controller.selectionEnd, 1);
      expect(() => controller.selection = const TextSelection.collapsed(9),
          throwsArgumentError);
      controller.clear();
      expect(controller.text, isEmpty);
      expect(controller.selection, const TextSelection.collapsed(0));
    });

    test('a listener with no argument works, and can be removed', () {
      final TextEditingController controller = TextEditingController('a');
      int calls = 0;
      void listener() => calls++;
      controller.addListener(listener);
      controller.text = 'b';
      expect(calls, 1);
      controller.removeListener(listener);
      controller.text = 'c';
      expect(calls, 1);
      final List<String> seen = <String>[];
      controller
        ..addListener(seen.add)
        ..text = 'd';
      expect(seen, <String>['d'], reason: "this framework's shape still works");
    });

    test('it is a Listenable', () {
      final Listenable listenable = TextEditingController();
      int calls = 0;
      listenable.addListener(() => calls++);
      (listenable as TextEditingController).text = 'x';
      expect(calls, 1);
    });
  });
}
