/// The public surface has to be usable from the public import alone.
///
/// Every other test in this suite imports `package:dart_ui/src/...` directly,
/// which is convenient and hides a specific failure: a type can be returned by
/// an exported API while its own declaration stays unexported, so the name is
/// unspeakable to an application. `dart analyze` does not catch it, because
/// inside the package the file is reachable either way.
///
/// So this file imports **only** `package:dart_ui/dart_ui.dart` and names each
/// type it uses. A missing export is a compile error here, before it is a bug
/// report from someone who cannot write down the type of a variable.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('public surface', () {
    test('geometry, graphics and layout types are nameable', () {
      const Offset offset = Offset(3, 4);
      const Size size = Size(10, 20);
      final Rect rect = Rect.fromLTWH(0, 0, size.width, size.height);
      final Transform2D transform =
          Transform2D.translation(offset.dx, offset.dy);
      final BoxConstraints constraints = BoxConstraints.tightFor(width: 10);
      const EdgeInsets insets = EdgeInsets.all(4);

      expect(rect.contains(offset), isTrue);
      expect(transform.transformRect(rect).left, 3);
      expect(constraints.isTight, isFalse);
      expect(insets.horizontal, 8);
    });

    test('the Unicode algorithms are nameable and agree with each other', () {
      // A decomposed 'a' with a combining acute: one grapheme, two code units,
      // and NFC has to fuse it. Three annexes, one string.
      const String decomposed = 'á';

      expect(nfc(decomposed), 'á');
      expect(nfd('á'), decomposed);
      expect(isNfc(decomposed), isNot(QuickCheck.yes));

      expect(
        GraphemeBreaks.next(decomposed, 0),
        2,
        reason: 'the mark belongs to its base',
      );

      final List<ScriptRun> runs = itemize('abcאב');
      expect(runs.length, 2);
      expect(runs.first.script, Script.latn);
      expect(runs.last.script, Script.hebr);

      final BidiParagraph bidi = BidiParagraph.resolve('abcאב');
      expect(bidi.levels.first.isEven, isTrue);
      expect(bidi.levels.last.isOdd, isTrue, reason: 'Hebrew resolves to RTL');
    });

    test('word break and case mapping are nameable', () {
      expect(WordBreaks.next('hello world', 0), 5);
      expect(toUpperCase('straße'), 'STRASSE');
      expect(caseFold('Straße'), caseFold('STRASSE'));
    });

    test('the text pipeline is nameable end to end', () {
      final FontRegistry registry = FontRegistry.instance;
      final Typeface? face = registry.uiTypeface;
      if (face == null) {
        // No system font on this machine: the types still had to resolve for
        // this file to compile, which is what the test is for.
        return;
      }

      final ScaledTypeface scaled = ScaledTypeface(face, 16);
      final Paragraph paragraph = Paragraph.single(
        'Hello',
        TextStyle(font: scaled),
        maxWidth: 1000,
      );

      expect(paragraph.lines, hasLength(1));
      expect(paragraph.height, greaterThan(0));

      final TextPosition position = paragraph.getPositionForOffset(Offset.zero);
      expect(position.offset, 0);
      expect(paragraph.getBoxesForSelection(0, 5), isNotEmpty);
    });

    test('animation types are nameable and the clock is injectable', () {
      // The clock is required, not defaulted: there is no ambient time in this
      // framework, which is the property that keeps the suite non-flaky.
      final AnimationClock clock = AnimationClock();
      final AnimationController controller = AnimationController(
        clock: clock,
        duration: const Duration(milliseconds: 100),
      );
      addTearDown(controller.dispose);

      final Animation<double> curved = CurvedAnimation(
        parent: controller,
        curve: Curves.easeInOut,
      );

      expect(curved.value, 0);
      expect(Curves.linear.transform(0.5), 0.5);
      expect(controller.status, AnimationStatus.dismissed);
    });

    test('the application shell is nameable', () {
      // Not started - starting needs a backend and a window. Naming the types
      // is the point: an application has to be able to declare them.
      const ApplicationOptions options = ApplicationOptions();
      expect(options, isA<ApplicationOptions>());
      expect(runApp, isA<Function>());
      expect(ApplicationLifecycleState.values, isNotEmpty);
    });

    test('rendering contracts are nameable without naming a backend', () {
      final Framebuffer buffer = Framebuffer.allocate(width: 4, height: 4);
      expect(buffer.bytesPerRow, 16);
      expect(buffer.format, PixelFormat.bgra8888Premultiplied);

      // The target is described by a surface, not by pixels: that indirection
      // is what lets the same contract serve a window and a memory buffer.
      const MemorySurfaceDescriptor surface = MemorySurfaceDescriptor(
        pixelWidth: 4,
        pixelHeight: 4,
      );
      final MemoryRenderTarget target = MemoryRenderTarget(surface);
      addTearDown(target.dispose);

      expect(Capability.values, contains(Capability.gpuPresentation));
    });
  });
}
