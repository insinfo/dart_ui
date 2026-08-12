/// Popups: menus, tooltips, combo dropdowns and modal overlays.
///
/// Section 29.6 makes two demands that pull in opposite directions. A popup
/// must be placed correctly against a *screen*, flipping and sliding when it
/// does not fit - and a popup may live either inside the owner's surface or in
/// a separate native window, a choice only the backend can make (Wayland's
/// `xdg_popup` does not even let a client know where its window is).
///
/// The resolution here is that placement is a pure function. [PopupPositioner]
/// computes a rect from an anchor, a size, a work area and a set of allowed
/// adjustments, and it is the same computation whether the result becomes an
/// overlay rect inside one surface or the geometry handed to `xdg_positioner`.
/// Nothing in this file knows what a window is.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';

/// Which edge or corner of the anchor the popup attaches to.
enum PopupAnchorPoint {
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  center,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight;

  /// The point in [rect] this constant names.
  Offset resolve(Rect rect) {
    final double x = switch (this) {
      PopupAnchorPoint.topLeft ||
      PopupAnchorPoint.centerLeft ||
      PopupAnchorPoint.bottomLeft =>
        rect.left,
      PopupAnchorPoint.topCenter ||
      PopupAnchorPoint.center ||
      PopupAnchorPoint.bottomCenter =>
        rect.left + rect.width / 2,
      PopupAnchorPoint.topRight ||
      PopupAnchorPoint.centerRight ||
      PopupAnchorPoint.bottomRight =>
        rect.right,
    };
    final double y = switch (this) {
      PopupAnchorPoint.topLeft ||
      PopupAnchorPoint.topCenter ||
      PopupAnchorPoint.topRight =>
        rect.top,
      PopupAnchorPoint.centerLeft ||
      PopupAnchorPoint.center ||
      PopupAnchorPoint.centerRight =>
        rect.top + rect.height / 2,
      PopupAnchorPoint.bottomLeft ||
      PopupAnchorPoint.bottomCenter ||
      PopupAnchorPoint.bottomRight =>
        rect.bottom,
    };
    return Offset(x, y);
  }

  /// This point mirrored across the anchor's centre, used when a flip is
  /// applied.
  PopupAnchorPoint get flippedVertically => switch (this) {
        PopupAnchorPoint.topLeft => PopupAnchorPoint.bottomLeft,
        PopupAnchorPoint.topCenter => PopupAnchorPoint.bottomCenter,
        PopupAnchorPoint.topRight => PopupAnchorPoint.bottomRight,
        PopupAnchorPoint.bottomLeft => PopupAnchorPoint.topLeft,
        PopupAnchorPoint.bottomCenter => PopupAnchorPoint.topCenter,
        PopupAnchorPoint.bottomRight => PopupAnchorPoint.topRight,
        PopupAnchorPoint.centerLeft ||
        PopupAnchorPoint.center ||
        PopupAnchorPoint.centerRight =>
          this,
      };

  PopupAnchorPoint get flippedHorizontally => switch (this) {
        PopupAnchorPoint.topLeft => PopupAnchorPoint.topRight,
        PopupAnchorPoint.centerLeft => PopupAnchorPoint.centerRight,
        PopupAnchorPoint.bottomLeft => PopupAnchorPoint.bottomRight,
        PopupAnchorPoint.topRight => PopupAnchorPoint.topLeft,
        PopupAnchorPoint.centerRight => PopupAnchorPoint.centerLeft,
        PopupAnchorPoint.bottomRight => PopupAnchorPoint.bottomLeft,
        PopupAnchorPoint.topCenter ||
        PopupAnchorPoint.center ||
        PopupAnchorPoint.bottomCenter =>
          this,
      };
}

/// What the positioner may do when the popup does not fit.
///
/// Named after the `xdg_positioner` constraint adjustments deliberately: the
/// Wayland backend can pass these through untranslated, and every other
/// backend implements the same semantics rather than each inventing its own.
enum PopupAdjustment { flipX, flipY, slideX, slideY, resizeX, resizeY }

/// How the popup is dismissed.
enum PopupDismissPolicy {
  /// Any click outside, or Escape, closes it. Menus and tooltips.
  lightDismiss,

  /// Only an explicit close does. Modal dialogs.
  explicit,
}

/// Where the backend should put the popup's pixels.
///
/// The framework asks; the backend decides, because only it knows whether the
/// popup would extend past the owner window and whether the platform allows an
/// override-redirect window at all.
enum PopupSurfaceKind {
  /// Composited into the owner's surface. No extra window, no extra frame -
  /// correct whenever the popup fits inside the owner.
  sameSurface,

  /// A separate top-level: needed when the popup must escape the owner's
  /// bounds, and the only option for a menu near a screen edge.
  nativeWindow,
}

/// One placement request.
final class PopupRequest {
  const PopupRequest({
    required this.anchorRect,
    required this.size,
    this.anchorPoint = PopupAnchorPoint.bottomLeft,
    this.popupPoint = PopupAnchorPoint.topLeft,
    this.offset = Offset.zero,
    this.adjustments = const <PopupAdjustment>{
      PopupAdjustment.flipY,
      PopupAdjustment.slideX,
    },
  });

  /// The owner's rect, in the same space as the work area.
  final Rect anchorRect;

  /// The popup's desired size.
  final Size size;

  /// The point on [anchorRect] to attach to.
  final PopupAnchorPoint anchorPoint;

  /// The point on the popup that meets [anchorPoint].
  final PopupAnchorPoint popupPoint;

  /// A nudge applied after attachment, for a menu's shadow gap.
  final Offset offset;

  final Set<PopupAdjustment> adjustments;
}

/// The placement actually achieved.
final class PopupPlacement {
  const PopupPlacement({
    required this.rect,
    required this.flippedX,
    required this.flippedY,
    required this.slidX,
    required this.slidY,
    required this.resized,
  });

  final Rect rect;
  final bool flippedX;
  final bool flippedY;
  final bool slidX;
  final bool slidY;
  final bool resized;

  /// Whether the popup ended up exactly where it asked to be.
  bool get isUnadjusted =>
      !flippedX && !flippedY && !slidX && !slidY && !resized;

  @override
  String toString() => 'PopupPlacement($rect'
      '${flippedX ? ', flipX' : ''}${flippedY ? ', flipY' : ''}'
      '${slidX ? ', slideX' : ''}${slidY ? ', slideY' : ''}'
      '${resized ? ', resized' : ''})';
}

/// Places a popup inside a work area, applying only the allowed adjustments.
///
/// The order is fixed and matters: **flip, then slide, then resize.** Flipping
/// preserves the relationship to the anchor (a menu still points at its
/// button), sliding preserves the size but not the relationship, and resizing
/// gives up the size. Trying them in any other order produces a menu that is
/// scrolled when it could simply have opened upward.
final class PopupPositioner {
  const PopupPositioner();

  PopupPlacement place(PopupRequest request, Rect workArea) {
    Rect rect = _attach(
      request,
      anchorPoint: request.anchorPoint,
      popupPoint: request.popupPoint,
      size: request.size,
    );

    bool flippedX = false;
    bool flippedY = false;

    if (_overflowsVertically(rect, workArea) &&
        request.adjustments.contains(PopupAdjustment.flipY)) {
      final Rect flipped = _attach(
        request,
        anchorPoint: request.anchorPoint.flippedVertically,
        popupPoint: request.popupPoint.flippedVertically,
        size: request.size,
        invertOffsetY: true,
      );
      // Only keep the flip when it actually helps; a popup taller than the
      // screen overflows both ways and flipping it just moves the clipping.
      if (_verticalOverflow(flipped, workArea) <
          _verticalOverflow(rect, workArea)) {
        rect = flipped;
        flippedY = true;
      }
    }

    if (_overflowsHorizontally(rect, workArea) &&
        request.adjustments.contains(PopupAdjustment.flipX)) {
      final Rect flipped = _attach(
        request,
        anchorPoint: request.anchorPoint.flippedHorizontally,
        popupPoint: request.popupPoint.flippedHorizontally,
        size: Size(rect.width, rect.height),
        invertOffsetX: true,
      );
      if (_horizontalOverflow(flipped, workArea) <
          _horizontalOverflow(rect, workArea)) {
        rect = Rect.fromLTWH(flipped.left, rect.top, rect.width, rect.height);
        flippedX = true;
      }
    }

    bool slidX = false;
    bool slidY = false;
    if (request.adjustments.contains(PopupAdjustment.slideX)) {
      final double slid =
          _slide(rect.left, rect.width, workArea.left, workArea.right);
      if (slid != rect.left) {
        rect = Rect.fromLTWH(slid, rect.top, rect.width, rect.height);
        slidX = true;
      }
    }
    if (request.adjustments.contains(PopupAdjustment.slideY)) {
      final double slid =
          _slide(rect.top, rect.height, workArea.top, workArea.bottom);
      if (slid != rect.top) {
        rect = Rect.fromLTWH(rect.left, slid, rect.width, rect.height);
        slidY = true;
      }
    }

    bool resized = false;
    if (request.adjustments.contains(PopupAdjustment.resizeX) &&
        rect.right > workArea.right) {
      rect = Rect.fromLTWH(
        rect.left,
        rect.top,
        (workArea.right - rect.left).clamp(0.0, rect.width),
        rect.height,
      );
      resized = true;
    }
    if (request.adjustments.contains(PopupAdjustment.resizeY) &&
        rect.bottom > workArea.bottom) {
      rect = Rect.fromLTWH(
        rect.left,
        rect.top,
        rect.width,
        (workArea.bottom - rect.top).clamp(0.0, rect.height),
      );
      resized = true;
    }

    return PopupPlacement(
      rect: rect,
      flippedX: flippedX,
      flippedY: flippedY,
      slidX: slidX,
      slidY: slidY,
      resized: resized,
    );
  }

  /// Whether this placement needs a window of its own.
  ///
  /// The rule is exactly "does it still fit in the owner": a popup wholly
  /// inside the owner's client area is cheaper as an overlay, and one that is
  /// not cannot be an overlay at all.
  PopupSurfaceKind surfaceFor(
    PopupPlacement placement,
    Rect ownerClientArea, {
    bool nativeWindowsAvailable = true,
  }) {
    final bool fits = placement.rect.left >= ownerClientArea.left &&
        placement.rect.top >= ownerClientArea.top &&
        placement.rect.right <= ownerClientArea.right &&
        placement.rect.bottom <= ownerClientArea.bottom;
    if (fits) return PopupSurfaceKind.sameSurface;
    return nativeWindowsAvailable
        ? PopupSurfaceKind.nativeWindow
        : PopupSurfaceKind.sameSurface;
  }

  Rect _attach(
    PopupRequest request, {
    required PopupAnchorPoint anchorPoint,
    required PopupAnchorPoint popupPoint,
    required Size size,
    bool invertOffsetX = false,
    bool invertOffsetY = false,
  }) {
    final Offset anchor = anchorPoint.resolve(request.anchorRect);
    final Offset local =
        popupPoint.resolve(Rect.fromLTWH(0, 0, size.width, size.height));
    final double dx = invertOffsetX ? -request.offset.dx : request.offset.dx;
    final double dy = invertOffsetY ? -request.offset.dy : request.offset.dy;
    return Rect.fromLTWH(
      anchor.dx - local.dx + dx,
      anchor.dy - local.dy + dy,
      size.width,
      size.height,
    );
  }

  static bool _overflowsVertically(Rect rect, Rect area) =>
      rect.top < area.top || rect.bottom > area.bottom;

  static bool _overflowsHorizontally(Rect rect, Rect area) =>
      rect.left < area.left || rect.right > area.right;

  static double _verticalOverflow(Rect rect, Rect area) =>
      (area.top - rect.top).clamp(0.0, double.infinity) +
      (rect.bottom - area.bottom).clamp(0.0, double.infinity);

  static double _horizontalOverflow(Rect rect, Rect area) =>
      (area.left - rect.left).clamp(0.0, double.infinity) +
      (rect.right - area.right).clamp(0.0, double.infinity);

  static double _slide(double start, double extent, double min, double max) {
    // Clamp the far edge first, then the near edge: when the popup is wider
    // than the area, the near edge wins and the overflow is on the far side,
    // which is where a scrollbar or a resize would go.
    double result = start;
    if (result + extent > max) result = max - extent;
    if (result < min) result = min;
    return result;
  }
}

/// One popup that is currently open.
final class PopupEntry {
  PopupEntry({
    required this.id,
    required this.placement,
    required this.surfaceKind,
    this.dismissPolicy = PopupDismissPolicy.lightDismiss,
    this.grabsInput = false,
    this.ownerId,
    this.onDismiss,
  });

  final int id;
  final PopupPlacement placement;
  final PopupSurfaceKind surfaceKind;
  final PopupDismissPolicy dismissPolicy;

  /// Whether input outside the popup is denied to everything else.
  ///
  /// A menu grabs; a tooltip does not. On Wayland this becomes the grab that
  /// needs a valid input serial, which is why the flag is part of the request
  /// rather than something the backend infers.
  final bool grabsInput;

  /// The popup this one was opened from, for a submenu chain.
  final int? ownerId;

  final void Function()? onDismiss;
}

/// The open popup stack for one window.
///
/// A stack rather than a set, because dismissal is inherently ordered:
/// closing a menu must close its submenus, and Escape closes exactly one
/// level.
final class PopupStack {
  final List<PopupEntry> _entries = <PopupEntry>[];
  int _nextId = 1;

  List<PopupEntry> get entries => List<PopupEntry>.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  PopupEntry? get topmost => _entries.isEmpty ? null : _entries.last;

  /// Whether any open popup is grabbing input.
  bool get hasInputGrab => _entries.any((PopupEntry entry) => entry.grabsInput);

  int open({
    required PopupPlacement placement,
    required PopupSurfaceKind surfaceKind,
    PopupDismissPolicy dismissPolicy = PopupDismissPolicy.lightDismiss,
    bool grabsInput = false,
    int? ownerId,
    void Function()? onDismiss,
  }) {
    final int id = _nextId++;
    _entries.add(PopupEntry(
      id: id,
      placement: placement,
      surfaceKind: surfaceKind,
      dismissPolicy: dismissPolicy,
      grabsInput: grabsInput,
      ownerId: ownerId,
      onDismiss: onDismiss,
    ));
    return id;
  }

  /// Closes [id] and every popup opened from it, deepest first.
  ///
  /// Returns the ids actually closed, which a backend uses to destroy the
  /// matching native windows in the order the protocol requires.
  List<int> close(int id) {
    final List<int> closed = <int>[];
    void collect(int target) {
      for (final PopupEntry entry in _entries) {
        if (entry.ownerId == target) collect(entry.id);
      }
      closed.add(target);
    }

    if (!_entries.any((PopupEntry entry) => entry.id == id)) {
      return const <int>[];
    }
    collect(id);
    for (final int target in closed) {
      final int index =
          _entries.indexWhere((PopupEntry entry) => entry.id == target);
      if (index < 0) continue;
      final PopupEntry entry = _entries.removeAt(index);
      entry.onDismiss?.call();
    }
    return closed;
  }

  /// Applies a click at [point], in the same space as the placements.
  ///
  /// Returns true when the click was consumed by dismissal - the caller must
  /// then *not* deliver it to whatever is underneath, which is what stops a
  /// click that closes a menu from also pressing the button behind it.
  /// A click inside an open popup dismisses everything above it and nothing
  /// else, which is what makes clicking a parent menu close only its submenu.
  bool handleOutsideClick(Offset point) {
    int containing = -1;
    for (int i = _entries.length - 1; i >= 0; i--) {
      if (_entries[i].placement.rect.contains(point)) {
        containing = i;
        break;
      }
    }
    bool consumed = false;
    while (_entries.length > containing + 1) {
      final PopupEntry entry = _entries.last;
      if (entry.dismissPolicy != PopupDismissPolicy.lightDismiss) {
        // An explicit-dismiss popup does not close, but swallows the click
        // when it holds a grab: that is what "modal" means.
        return consumed || entry.grabsInput;
      }
      close(entry.id);
      consumed = true;
    }
    return consumed;
  }

  /// Closes the topmost light-dismiss popup, for Escape. Returns true when one
  /// was closed.
  bool dismissTopmost() {
    final PopupEntry? top = topmost;
    if (top == null) return false;
    if (top.dismissPolicy != PopupDismissPolicy.lightDismiss) return false;
    close(top.id);
    return true;
  }

  void closeAll() {
    while (_entries.isNotEmpty) {
      close(_entries.last.id);
    }
  }
}
