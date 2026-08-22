import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('DataGallery', () {
    test('mounts every data control headless', () {
      final harness = _GalleryHarness();
      harness.frame();

      expect(harness.find<RenderTreeView>(), isNotNull);
      expect(harness.find<RenderDataGridHeader>(), isNotNull);
      expect(harness.find<RenderDataGridBody>(), isNotNull);
      expect(harness.find<RenderNumberBox>(), isNotNull);
      expect(harness.find<RenderInfoBarChrome>(), isNotNull);
      expect(harness.find<RenderBadge>(), isNotNull);
      expect(harness.find<RenderChip>(), isNotNull);
      expect(harness.find<RenderAvatar>(), isNotNull);
      expect(harness.find<RenderCard>(), isNotNull);
      harness.dispose();
    });

    test('the model drives the tree and the grid', () {
      final harness = _GalleryHarness();
      harness.frame();

      // 'src' starts expanded: its children are rows.
      expect(harness.model.expandedNodes, contains('src'));
      final RenderTreeView tree = harness.find<RenderTreeView>()!;
      expect(tree.virtualization.itemCount, greaterThan(3));

      final RenderDataGridBody body = harness.find<RenderDataGridBody>()!;
      expect(body.virtualization.itemCount, DataGalleryModel.gridRowCount);
      expect(body.childCount, lessThan(20),
          reason: 'ten thousand rows stay virtualized inside the gallery');
      harness.dispose();
    });

    test('a toast shown through the model appears and can be dismissed', () {
      final harness = _GalleryHarness();
      harness.frame();

      final int id = harness.model.toasts.show('Hello', duration: null);
      harness.frame();
      expect(
        harness.model.toasts.entries.map((ToastEntry e) => e.title),
        contains('Hello'),
      );

      harness.model.toasts.dismiss(id);
      harness.frame();
      expect(harness.model.toasts.entries, isEmpty);
      harness.dispose();
    });
  });
}

final class _GalleryHarness {
  _GalleryHarness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(360, 700)),
      ),
    );
    _mount();
  }

  final DataGalleryModel model = DataGalleryModel();
  late final BuildOwner owner;

  void _mount() => owner.updateRoot(DataGallery(model: model));

  void frame({int maxPasses = 10}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the gallery never settled');
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
