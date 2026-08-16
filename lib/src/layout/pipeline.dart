/// The owner that drives one render tree through a frame.
///
/// A scheduler calls [flushLayout] then [flushPaint]; this class knows which
/// nodes are dirty and in what order they must be visited, and nothing else.
/// It deliberately owns no timing: what makes a frame happen is the
/// scheduler's business, and keeping the two apart is what lets a test run a
/// frame synchronously with no clock at all.
library;

import 'package:meta/meta.dart';

import '../geometry/offset.dart';
import '../graphics/display_list.dart';
import 'box_constraints.dart';
import 'layout_errors.dart';
import 'render_box.dart';

/// Holds the root of a render tree and runs layout and paint over it.
final class PipelineOwner {
  PipelineOwner({
    BoxConstraints? rootConstraints,
    this.onNeedsVisualUpdate,
  }) : _rootConstraints = rootConstraints ?? BoxConstraints();

  /// Called when the tree becomes dirty while it was clean.
  ///
  /// This is the hook a scheduler uses to request the next frame. It is a
  /// plain callback rather than a stream because it must run synchronously
  /// with the mutation - a frame request that arrives one microtask late is a
  /// frame of latency on every interaction.
  void Function()? onNeedsVisualUpdate;

  RenderBox? _root;
  BoxConstraints _rootConstraints;
  bool _rootConstraintsDirty = true;

  final List<RenderBox> _nodesNeedingLayout = <RenderBox>[];
  final List<RenderBox> _nodesNeedingPaint = <RenderBox>[];

  /// Reused across passes so that draining the dirty list allocates nothing
  /// per frame, per section 6.5.
  final List<RenderBox> _layoutScratch = <RenderBox>[];

  /// How many times the dirty list may refill during one [flushLayout] before
  /// layout is declared not to converge.
  ///
  /// The number is a judgement, and here is the reasoning behind this one. A
  /// *legitimate* refill happens when a node's relayout dirties something
  /// outside its own subtree - a scroll position that changed its extents, a
  /// text field that told an overlay to move. Those cascades are shallow: each
  /// one is a step along a dependency chain a human wrote, and a chain more
  /// than a handful long is already a design nobody can reason about. A
  /// *cycle*, on the other hand, refills forever. Thirty-two leaves an order of
  /// magnitude of headroom over any real cascade while still failing in
  /// microseconds rather than hanging the frame - which matters, because the
  /// symptom of no limit at all is a frozen window with no message, the single
  /// worst failure mode a UI framework has.
  ///
  /// Public so a test can assert against it by name rather than by copying the
  /// number, and so the message can quote it.
  static const int maxLayoutPasses = 32;

  /// The pass at which the owner starts *recording* who is being re-laid-out.
  ///
  /// Counting is not free - it is a map write per node per pass - and layout is
  /// a per-frame path, so it stays off for every pass a healthy tree ever
  /// reaches. By the time this many passes have gone by, something is wrong and
  /// the diagnosis is worth more than the microseconds.
  static const int _diagnosticsAfterPass = 8;

  RenderBox? get root => _root;

  /// Replaces the tree. The new root must not already have a parent.
  set root(RenderBox? value) {
    if (identical(value, _root)) return;
    if (value != null && value.parent != null) {
      throw StateError(
        'a ${value.runtimeType} with a parent cannot be a pipeline root; it '
        'would be laid out by two different owners.',
      );
    }
    _root?.detach();
    _nodesNeedingLayout.clear();
    _nodesNeedingPaint.clear();
    _root = value;
    value?.attach(this);
  }

  /// The constraints the root is laid out under - in practice the window's
  /// size, tight.
  BoxConstraints get rootConstraints => _rootConstraints;

  set rootConstraints(BoxConstraints value) {
    if (value == _rootConstraints) return;
    _rootConstraints = value;
    // The root's own layout() detects the change and re-runs; marking the root
    // dirty here would be a lie, since the tree itself is still consistent
    // with the geometry it was last given.
    _rootConstraintsDirty = true;
    requestVisualUpdate();
  }

  bool get needsLayout =>
      _rootConstraintsDirty ||
      _nodesNeedingLayout.isNotEmpty ||
      (_root?.needsLayout ?? false);

  bool get needsPaint => _nodesNeedingPaint.isNotEmpty;

  /// The relayout boundaries scheduled for the next [flushLayout].
  ///
  /// Exposed because it is the observable proof that the boundary rule holds:
  /// dirtying a node deep inside a tightly constrained subtree must leave
  /// exactly that subtree's boundary here, and not the root.
  List<RenderBox> get nodesNeedingLayout =>
      List<RenderBox>.unmodifiable(_nodesNeedingLayout);

  List<RenderBox> get nodesNeedingPaint =>
      List<RenderBox>.unmodifiable(_nodesNeedingPaint);

  @internal
  void addNodeNeedingLayout(RenderBox node) {
    _nodesNeedingLayout.add(node);
    requestVisualUpdate();
  }

  @internal
  void addNodeNeedingPaint(RenderBox node) {
    _nodesNeedingPaint.add(node);
    requestVisualUpdate();
  }

  void requestVisualUpdate() => onNeedsVisualUpdate?.call();

  /// Brings every dirty node's geometry up to date.
  ///
  /// The root is offered its constraints first - which is a no-op when neither
  /// the constraints nor the root changed - and then the dirty boundaries are
  /// drained shallowest first. Depth order matters: an ancestor's relayout may
  /// clean a descendant that is also in the list, and doing the descendant
  /// first would do that work twice.
  void flushLayout() {
    final RenderBox? root = _root;
    if (root == null) return;
    root.layout(_rootConstraints);
    _rootConstraintsDirty = false;

    int pass = 0;
    Map<RenderBox, int>? relayouts;
    while (_nodesNeedingLayout.isNotEmpty) {
      if (++pass > maxLayoutPasses) {
        _layoutScratch.clear();
        throw _cycleError(pass - 1, relayouts);
      }
      if (pass == _diagnosticsAfterPass) {
        relayouts = <RenderBox, int>{};
      }
      _layoutScratch
        ..clear()
        ..addAll(_nodesNeedingLayout);
      _nodesNeedingLayout.clear();
      _layoutScratch.sort((RenderBox a, RenderBox b) => a.depth - b.depth);
      for (int i = 0; i < _layoutScratch.length; i++) {
        final RenderBox node = _layoutScratch[i];
        // Both tests can fail legitimately: an ancestor earlier in this pass
        // may have cleaned this node, and a node may have been removed from
        // the tree since it was marked.
        if (node.needsLayout && identical(node.owner, this)) {
          if (relayouts != null) {
            relayouts[node] = (relayouts[node] ?? 0) + 1;
          }
          node.layoutWithoutResize();
        }
      }
    }
    _layoutScratch.clear();
  }

  /// Builds the failure, with the reduced tree section 25.7 asks for.
  ///
  /// The suspects are the nodes re-laid-out the most since counting began. The
  /// tree printed for each is its ancestor chain and nothing else: a render
  /// tree that fails this check is usually a whole application, and dumping it
  /// buries the two nodes that matter.
  LayoutCycleError _cycleError(int passes, Map<RenderBox, int>? relayouts) {
    final List<RenderBox> suspects = <RenderBox>[];
    final StringBuffer buffer = StringBuffer();
    if (relayouts == null || relayouts.isEmpty) {
      buffer.write(
        'No node was recorded: the dirty list refilled with nodes that were '
        'already clean by the time they were reached.',
      );
      return LayoutCycleError(
        passes: passes,
        suspects: suspects,
        diagnosticTree: buffer.toString(),
      );
    }
    final List<MapEntry<RenderBox, int>> ranked = relayouts.entries.toList()
      ..sort((MapEntry<RenderBox, int> a, MapEntry<RenderBox, int> b) =>
          b.value - a.value);
    final int worst = ranked.first.value;
    for (final MapEntry<RenderBox, int> entry in ranked) {
      // Only the nodes that came back as often as the worst one: a cycle's
      // members all come back the same number of times, and everything below
      // that count is collateral.
      if (entry.value < worst || suspects.length >= 4) break;
      suspects.add(entry.key);
    }

    buffer.writeln(
      'Re-laid-out ${suspects.length == 1 ? 'node' : 'nodes'}, each $worst '
      'times in the last ${passes - _diagnosticsAfterPass + 1} passes:',
    );
    for (final RenderBox suspect in suspects) {
      buffer.writeln(_ancestorChain(suspect));
    }
    return LayoutCycleError(
      passes: passes,
      suspects: suspects,
      diagnosticTree: buffer.toString(),
    );
  }

  /// `RenderFoo -> RenderBar -> RenderBaz#Size(10.0, 10.0)`, root first.
  static String _ancestorChain(RenderBox node) {
    final List<String> parts = <String>[];
    for (RenderBox? step = node; step != null; step = step.parent) {
      parts.add(step.toString());
    }
    final StringBuffer buffer = StringBuffer('  ');
    for (int i = parts.length - 1; i >= 0; i--) {
      buffer.write(parts[i]);
      if (i > 0) buffer.write(' -> ');
    }
    return buffer.toString();
  }

  /// Appends the whole tree's drawing commands to [list].
  ///
  /// [list] is not reset here: the arena belongs to the caller, who may want
  /// to prepend a clear or a device transform, and who knows whether this tree
  /// is the only thing in the frame.
  ///
  /// The entire tree is re-emitted, not just the dirty nodes. With no layer
  /// tree there is nothing retained to reuse, so a partial walk would produce
  /// an incomplete list rather than a cheaper one. See
  /// [RenderBox.markNeedsPaint].
  void flushPaint(DisplayList list) {
    final RenderBox? root = _root;
    if (root == null) return;
    if (root.needsLayout) {
      throw StateError(
        'flushPaint ran with a dirty layout. Painting geometry that has not '
        'been recomputed draws the previous frame at the current frame\'s '
        'sizes; call flushLayout first.',
      );
    }
    root.paint(list, Offset.zero);
    root.clearNeedsPaintSubtree();
    _nodesNeedingPaint.clear();
  }

  /// The whole frame: geometry, then commands.
  void drawFrame(DisplayList list) {
    flushLayout();
    flushPaint(list);
  }
}
