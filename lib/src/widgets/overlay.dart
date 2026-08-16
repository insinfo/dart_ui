/// The layer that floating things live in, and the order they live in.
///
/// A window is not a single tree of content. A dialog, a menu, a tooltip, a
/// drag ghost and - the reason this file exists at all - a *route* all need to
/// paint above whatever else is on screen, in an order somebody decides, while
/// still being ordinary widgets built by ordinary parents.
///
/// [Overlay] is that layer and nothing else. It is deliberately **not** a
/// second popup positioner: `popup.dart` already computes where a floating
/// surface goes, in a form a Wayland `xdg_positioner` can consume directly, and
/// duplicating that arithmetic here would produce two answers to the same
/// question. An overlay entry is given the whole layer and places itself.
///
/// ## What `opaque` is for, and why there is no barrier widget
///
/// The single interesting property here is [OverlayEntry.opaque]. An opaque
/// entry declares "everything I am on top of is not visible", and the overlay
/// acts on that by not building those entries at all (or, with
/// [OverlayEntry.maintainState], by building them and hiding them). That one
/// flag is the modal barrier:
///
///   * nothing below is painted, so there is no wasted paint and no chance of
///     a half-covered control showing through;
///   * nothing below is hit-tested, so a click cannot reach a button that the
///     user cannot see - which is what "modal" actually means to a user;
///   * nothing below is in the tab ring while it is unbuilt.
///
/// A separate `ModalBarrier` widget would give the same visual result and none
/// of the guarantees: it would still paint the entries underneath, still lay
/// them out, and would rely on a full-screen absorbing rectangle being present
/// *and* on nothing being inserted above it later. The flag cannot be got
/// wrong that way, because the overlay is what reads it.
///
/// A translucent modal - a dialog with the page dimmed behind it - is the case
/// `opaque: false` exists for: the entry declares that it does not cover, the
/// entries below keep painting, and blocking input is then the caller's job
/// (`Navigator` does it with [IgnorePointer], see `navigator.dart`).
library;

import 'basic.dart';
import 'proxy.dart';
import 'widget.dart';

/// Builds a widget for a location in the tree.
typedef WidgetBuilder = Widget Function(BuildContext context);

/// One thing in an [Overlay], and the handle used to take it out again.
///
/// The entry is the identity, not the widget it builds: it survives every
/// rebuild of the overlay, it is what [OverlayState.insert] orders and what
/// [remove] removes, and it carries a [GlobalKey] so that reordering the stack
/// moves the *element* rather than tearing one down and building another.
final class OverlayEntry {
  OverlayEntry({
    required this.builder,
    bool opaque = false,
    bool maintainState = false,
  })  : _opaque = opaque,
        _maintainState = maintainState;

  /// Builds this entry's content. Called with the overlay's own context, so
  /// everything ambient at the overlay - theme, direction, media query - is
  /// visible to it, and nothing from wherever the entry was created is.
  final WidgetBuilder builder;

  /// A stable identity for this entry's element across reordering.
  final GlobalKey<_OverlayEntryState> _key =
      GlobalKey<_OverlayEntryState>(debugLabel: 'overlay entry');

  OverlayState? _overlay;
  bool _opaque;
  bool _maintainState;

  /// Whether this entry covers everything below it. See the library
  /// documentation: this is the modal barrier.
  bool get opaque => _opaque;

  set opaque(bool value) {
    if (value == _opaque) return;
    _opaque = value;
    _overlay?._markDirty();
  }

  /// Whether this entry is still *built* while something opaque covers it.
  ///
  /// False - the default - is the honest one for a transient thing: a tooltip
  /// that nobody can see should not be running. True is for an entry whose
  /// state is expensive or user-visible when it comes back: a page with a
  /// scroll position and a half-filled form, which is exactly why
  /// `PageRoute.maintainState` defaults to true.
  bool get maintainState => _maintainState;

  set maintainState(bool value) {
    if (value == _maintainState) return;
    _maintainState = value;
    _overlay?._markDirty();
  }

  /// The overlay this entry is in, or null when it is not in one.
  OverlayState? get overlay => _overlay;

  /// Whether this entry is currently in an overlay.
  bool get isInserted => _overlay != null;

  /// Removes this entry from its overlay.
  ///
  /// Throws when it is not in one: removing something twice is a bug in the
  /// caller's bookkeeping, and silently ignoring it is how an entry that
  /// *should* still be visible gets removed by a stale handle.
  void remove() {
    final OverlayState? overlay = _overlay;
    if (overlay == null) {
      throw StateError(
        'this OverlayEntry is not in an Overlay; it was either never inserted '
        'or has already been removed',
      );
    }
    overlay.remove(this);
  }

  /// Rebuilds just this entry.
  ///
  /// The whole point of an entry owning an element: a route repainting its
  /// transition must not rebuild the dialog above it and the page below it as
  /// well. A no-op when the entry is not built right now, which is the correct
  /// answer - it will be built from scratch when it comes back onstage.
  void markNeedsBuild() => _key.currentState?.markNeedsBuild();

  @override
  String toString() => 'OverlayEntry(opaque: $_opaque, '
      'maintainState: $_maintainState, inserted: ${_overlay != null})';
}

/// A stack of [OverlayEntry] objects, bottom first.
///
/// The state, not the widget, is the API: entries are inserted and removed
/// imperatively because the things that use an overlay - a route being pushed,
/// a menu opening under a cursor - are events, not declarative configuration
/// of the parent that happens to host the layer.
final class Overlay extends StatefulWidget {
  const Overlay({super.key, this.initialEntries = const <OverlayEntry>[]});

  /// Entries present from the first build.
  ///
  /// Needed because the first entry usually has to exist *before* the overlay
  /// is mounted: a `Navigator` creates its initial route in `initState`, which
  /// runs before its overlay has a state to insert into.
  final List<OverlayEntry> initialEntries;

  /// The nearest overlay, or null when there is none above [context].
  static OverlayState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_OverlayScope>()?.state;

  /// The nearest overlay.
  ///
  /// Throws rather than returning null, because every caller of this - a
  /// dialog, a menu, a route - has nowhere to put its content without one, and
  /// a null dereference three frames later names neither the widget that
  /// wanted an overlay nor the fact that none was installed.
  static OverlayState of(BuildContext context) {
    final OverlayState? overlay = maybeOf(context);
    if (overlay == null) {
      throw StateError(
        'no Overlay above ${context.widget.runtimeType}. Floating content - a '
        'route, a dialog, a menu - needs a layer to be put in; install an '
        'Overlay (a Navigator installs one of its own) above this widget.',
      );
    }
    return overlay;
  }

  @override
  OverlayState createState() => OverlayState();
}

/// The mutable stack behind an [Overlay].
final class OverlayState extends State<Overlay> {
  final List<OverlayEntry> _entries = <OverlayEntry>[];

  @override
  void initState() {
    super.initState();
    for (final OverlayEntry entry in widget.initialEntries) {
      _adopt(entry);
      _entries.add(entry);
    }
  }

  /// The entries, bottom first.
  List<OverlayEntry> get entries => List<OverlayEntry>.unmodifiable(_entries);

  int get length => _entries.length;

  /// Whether [entry] is in this overlay at all.
  bool contains(OverlayEntry entry) =>
      _entries.any((OverlayEntry other) => identical(other, entry));

  /// Whether [entry] is currently visible: in this overlay and not covered by
  /// an opaque entry above it.
  ///
  /// This is the reading of `opaque` in one method, and it is deliberately
  /// answered by walking down from the top: the *topmost* opaque entry is the
  /// one that matters, and an opaque entry in the middle of the stack hides
  /// what is below it without hiding what is above it.
  bool isOnstage(OverlayEntry entry) {
    for (int i = _entries.length - 1; i >= 0; i--) {
      final OverlayEntry candidate = _entries[i];
      if (identical(candidate, entry)) return true;
      if (candidate.opaque) return false;
    }
    return false;
  }

  /// Whether [entry]'s content is built right now - onstage, or offstage and
  /// kept alive by [OverlayEntry.maintainState].
  bool isBuilt(OverlayEntry entry) =>
      contains(entry) && (isOnstage(entry) || entry.maintainState);

  /// Inserts [entry] on top, or directly above [above], or directly below
  /// [below].
  void insert(OverlayEntry entry, {OverlayEntry? above, OverlayEntry? below}) =>
      insertAll(<OverlayEntry>[entry], above: above, below: below);

  /// Inserts [entries] as a block, keeping their relative order.
  void insertAll(
    Iterable<OverlayEntry> entries, {
    OverlayEntry? above,
    OverlayEntry? below,
  }) {
    if (above != null && below != null) {
      throw ArgumentError(
        'insertAll takes above or below, not both: two anchors can disagree '
        'and there is no rule that says which wins',
      );
    }
    final List<OverlayEntry> incoming = List<OverlayEntry>.of(entries);
    if (incoming.isEmpty) return;
    final int index = _insertionIndex(above: above, below: below);
    for (final OverlayEntry entry in incoming) {
      _adopt(entry);
    }
    _entries.insertAll(index, incoming);
    _markDirty();
  }

  /// Removes [entry]. Silently ignores an entry that is not here, because
  /// [OverlayEntry.remove] has already made that the error.
  void remove(OverlayEntry entry) {
    final int index =
        _entries.indexWhere((OverlayEntry other) => identical(other, entry));
    if (index < 0) return;
    _entries.removeAt(index);
    entry._overlay = null;
    _markDirty();
  }

  /// Removes several entries in one rebuild.
  void removeAll(Iterable<OverlayEntry> entries) {
    bool changed = false;
    for (final OverlayEntry entry in List<OverlayEntry>.of(entries)) {
      final int index =
          _entries.indexWhere((OverlayEntry other) => identical(other, entry));
      if (index < 0) continue;
      _entries.removeAt(index);
      entry._overlay = null;
      changed = true;
    }
    if (changed) _markDirty();
  }

  int _insertionIndex({OverlayEntry? above, OverlayEntry? below}) {
    if (above != null) {
      final int index =
          _entries.indexWhere((OverlayEntry other) => identical(other, above));
      if (index < 0) {
        throw ArgumentError('the "above" entry is not in this Overlay');
      }
      return index + 1;
    }
    if (below != null) {
      final int index =
          _entries.indexWhere((OverlayEntry other) => identical(other, below));
      if (index < 0) {
        throw ArgumentError('the "below" entry is not in this Overlay');
      }
      return index;
    }
    return _entries.length;
  }

  void _adopt(OverlayEntry entry) {
    final OverlayState? owner = entry._overlay;
    if (owner != null && !identical(owner, this)) {
      throw StateError(
        'this OverlayEntry is already in another Overlay; an entry is an '
        'identity and cannot be in two layers at once',
      );
    }
    entry._overlay = this;
  }

  void _markDirty() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    for (final OverlayEntry entry in _entries) {
      entry._overlay = null;
    }
    _entries.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Walked from the top down, because the question "is anything above me
    // opaque" can only be answered from above. `covered` becomes true at the
    // topmost opaque entry and stays true for everything under it.
    final List<Widget> children = <Widget>[];
    bool covered = false;
    for (int i = _entries.length - 1; i >= 0; i--) {
      final OverlayEntry entry = _entries[i];
      final bool onstage = !covered;
      if (entry.opaque) covered = true;
      if (!onstage && !entry.maintainState) continue;
      children.add(
        Positioned.fill(
          child: _OverlayEntryWidget(
            key: entry._key,
            entry: entry,
            onstage: onstage,
          ),
        ),
      );
    }
    return _OverlayScope(
      state: this,
      // Reversed back into bottom-first order: a Stack paints its children in
      // order and the last one is on top, which is the order entries are in.
      child: Stack(children: children.reversed.toList(growable: false)),
    );
  }
}

/// Publishes the overlay's state to its subtree.
final class _OverlayScope extends InheritedWidget {
  const _OverlayScope({required this.state, required super.child});

  final OverlayState state;

  @override
  bool updateShouldNotify(_OverlayScope oldWidget) =>
      !identical(state, oldWidget.state);
}

/// One entry's element: the thing a [GlobalKey] names and
/// [OverlayEntry.markNeedsBuild] rebuilds.
final class _OverlayEntryWidget extends StatefulWidget {
  const _OverlayEntryWidget({
    required super.key,
    required this.entry,
    required this.onstage,
  });

  final OverlayEntry entry;
  final bool onstage;

  @override
  State<_OverlayEntryWidget> createState() => _OverlayEntryState();
}

final class _OverlayEntryState extends State<_OverlayEntryWidget> {
  void markNeedsBuild() {
    if (!mounted) return;
    setState(() {});
  }

  /// [Visibility] rather than simply omitting the child, because this element
  /// only exists at all when the entry is onstage or asked to be maintained -
  /// and a maintained entry must keep its state while contributing no pixels,
  /// no hits and no space.
  @override
  Widget build(BuildContext context) => Visibility(
        visible: widget.onstage,
        maintainSize: false,
        child: widget.entry.builder(context),
      );
}
