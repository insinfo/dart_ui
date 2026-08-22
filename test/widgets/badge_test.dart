import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('Badge', () {
    test('sizes to its label and reads as text', () {
      final harness = _Harness(child: const Badge(label: '42'));
      harness.frame();

      final RenderBadge badge = harness.find<RenderBadge>()!;
      expect(badge.size.width, greaterThan(badge.size.height));

      final SemanticsSnapshot snapshot =
          SemanticsOwner().build(harness.owner.renderRoot);
      final SemanticsNode node = snapshot.nodes.firstWhere(
        (SemanticsNode n) => n.role == SemanticsRole.text,
      );
      expect(node.label, '42');
      harness.dispose();
    });
  });

  group('Chip', () {
    test('activates on click and deletes from the trailing glyph', () {
      int pressed = 0;
      int deleted = 0;
      final harness = _Harness(
        child: Chip(
          label: 'alpha',
          onPressed: () => pressed++,
          onDeleted: () => deleted++,
        ),
      );
      harness.frame();

      final RenderChip chip = harness.find<RenderChip>()!;
      final Offset labelPoint = chip.localToGlobal(const Offset(10, 10));
      chip.handlePointerEvent(_press(labelPoint));
      chip.handlePointerEvent(_release(labelPoint));
      expect(pressed, 1);
      expect(deleted, 0);

      final Offset deletePoint =
          chip.localToGlobal(Offset(chip.size.width - 8, 10));
      chip.handlePointerEvent(_press(deletePoint));
      chip.handlePointerEvent(_release(deletePoint));
      expect(pressed, 1);
      expect(deleted, 1);
      harness.dispose();
    });

    test('Delete and Backspace remove the chip from the keyboard', () {
      int deleted = 0;
      final harness = _Harness(
        child: Chip(label: 'beta', onDeleted: () => deleted++),
      );
      harness.frame();

      final RenderChip chip = harness.find<RenderChip>()!;
      chip.handleKeyEvent(_key(logicalKeyDelete));
      chip.handleKeyEvent(_key(logicalKeyBackspace));

      expect(deleted, 2);
      harness.dispose();
    });

    test('a chip with no callbacks is passive', () {
      final harness = _Harness(child: const Chip(label: 'quiet'));
      harness.frame();

      final RenderChip chip = harness.find<RenderChip>()!;
      expect(chip.enabled, isFalse);
      expect(chip.handleKeyEvent(_key(logicalKeyDelete)), isFalse);
      harness.dispose();
    });

    test('semantics: a button that can be dismissed, selected when selected',
        () {
      final harness = _Harness(
        child: Chip(label: 'tag', selected: true, onDeleted: () {}),
      );
      harness.frame();

      final SemanticsSnapshot snapshot =
          SemanticsOwner().build(harness.owner.renderRoot);
      final SemanticsNode node = snapshot.nodes.firstWhere(
        (SemanticsNode n) => n.role == SemanticsRole.button,
      );
      expect(node.label, 'tag');
      expect(node.states, contains(SemanticsState.selected));
      expect(node.actions, contains(SemanticsAction.dismiss));
      harness.dispose();
    });
  });

  group('Avatar', () {
    test('is square at its requested size and reads as an image', () {
      final harness = _Harness(
        child: const Avatar(initials: 'DU', size: 40, semanticsLabel: 'Dart UI'),
      );
      harness.frame();

      final RenderAvatar avatar = harness.find<RenderAvatar>()!;
      expect(avatar.size, const Size(40, 40));

      final SemanticsSnapshot snapshot =
          SemanticsOwner().build(harness.owner.renderRoot);
      final SemanticsNode node = snapshot.nodes.firstWhere(
        (SemanticsNode n) => n.role == SemanticsRole.image,
      );
      expect(node.label, 'Dart UI');
      harness.dispose();
    });
  });

  group('Card', () {
    test('pads its child on all sides', () {
      final harness = _Harness(
        child: const Card(
          padding: 12,
          child: SizedBox(width: 50, height: 30),
        ),
      );
      harness.frame();

      final RenderCard card = harness.find<RenderCard>()!;
      expect(card.size, const Size(74, 54));
      expect(card.child!.offsetFromParent, const Offset(12, 12));
      harness.dispose();
    });
  });
}

final class _Harness {
  _Harness({required this.child}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints(maxWidth: 300, maxHeight: 200),
      ),
    );
    _mount();
  }

  final Widget child;
  late final BuildOwner owner;

  void _mount() => owner.updateRoot(child);

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  T? find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is T) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  void dispose() => owner.dispose();
}

KeyDownEvent _key(int logicalKey) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    );

PointerDownEvent _press(Offset position) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );

PointerUpEvent _release(Offset position) => PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );
