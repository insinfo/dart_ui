/// What a backend must offer for a window to be readable by a screen reader.
///
/// One interface, three calls, and a deliberate asymmetry: the *window* knows
/// when its layout is settled and the *backend* knows how to speak to the
/// platform's accessibility API, so registration hands the backend a tree it
/// can read and the window keeps the job of saying when.
///
/// ## Why this file is not in `platform/`
///
/// It used to be, and it was the one file under `lib/src/platform/` that
/// imported the widget layer - because the tree it hands a backend is a
/// [SemanticsOwner], and that type lived in `widgets/`. The edge was recorded
/// and regretted in this header for as long as it existed: `platform`
/// describes what an operating system can do, and a description that needs a
/// widget to state itself has stopped being a description.
///
/// Two shortcuts were rejected on the way here, because both look cheaper
/// than they are:
///
///   * **declaring the edge**. `platform -> widgets` is dependency inversion,
///     not an exception worth documenting: it makes the lowest layer that
///     names an operating system depend on the highest one that draws;
///   * **passing the tree as `Object`** and casting inside the backend. That
///     keeps the import graph tidy by making the contract untypeable, trading
///     a layering diagram for a class of runtime failure.
///
/// So the tree moved instead. [SemanticsOwner] and everything it builds now
/// live in `semantics/`, a layer above `layout` and below `widgets`, and this
/// contract lives with them: what `register` carries is a semantic tree, so
/// the interface carrying it belongs at the layer that defines one. Nothing
/// left here names a platform type - a window is an `int` handle - and
/// `platform` is back to importing nothing above `scheduler`.
library;

import '../layout/render_box.dart';
import 'semantics.dart';

/// Where a backend reads the tree it publishes.
///
/// The root is a callback because it changes: a window's render root is
/// replaced when the tree is remounted, and a source that captured it once
/// would publish a detached tree for the rest of the process.
typedef AccessibilityTreeSource = ({
  SemanticsOwner owner,
  RenderBox? Function() root,
});

/// One window's live connection to the platform's accessibility API.
abstract interface class WindowAccessibility {
  /// Rebuilds the semantic tree, publishes what changed and raises the events
  /// assistive technology listens for.
  ///
  /// Call **after layout**: semantic nodes carry bounds taken from
  /// `RenderBox.size`, and a tree that has not been laid out either carries
  /// last frame's geometry or throws for want of any.
  ///
  /// Cheap when nothing changed - the diff is empty and nothing is published.
  /// Not free: the walk is O(render objects), which is why [AccessibilityHost]
  /// does not create one of these until somebody asks.
  void pump();

  /// Republishes unconditionally, for the changes a diff cannot see - a window
  /// that moved, so every element's screen bounds changed while no semantic
  /// property did.
  void republish();
}

/// A backend that can publish a window's semantic tree.
///
/// Implemented per platform and installed into [platformAccessibility] by the
/// backend's `initialize`. The application layer holds the interface and never
/// the implementation, which is what keeps `application.dart` free of
/// `#if Windows`.
abstract interface class AccessibilityHost {
  /// The name of the platform API this host speaks, for diagnostics.
  ///
  /// `UI Automation`, `AT-SPI`, `NSAccessibility`.
  String get apiName;

  /// Remembers that [nativeHandle] has a tree worth publishing.
  ///
  /// Expected to be **cheap** and to build nothing: on a machine with no
  /// assistive technology running - which is most machines, most of the time -
  /// this is all that ever happens, and a provider built here would cost every
  /// window a per-frame tree walk for nobody.
  void register(int nativeHandle, AccessibilityTreeSource source);

  /// The live connection for [nativeHandle], or null while nobody has asked.
  ///
  /// Null is the ordinary answer. A caller pumping every frame writes
  /// `forWindow(handle)?.pump()` and pays a map lookup when no client is
  /// attached.
  WindowAccessibility? forWindow(int nativeHandle);

  /// Forgets [nativeHandle] and tears down its provider if one was built.
  ///
  /// Skipping this leaves a client holding elements for a window that is gone,
  /// which it discovers by timing out rather than by being told.
  void unregister(int nativeHandle);
}

/// The installed host, or null on a platform with no accessibility bridge.
///
/// A single global rather than a field on the backend because a window's
/// native handle is the only key involved and the backend that created it is
/// the only one that could answer for it: a second host would have nothing to
/// disagree about. Set by a backend's `initialize` and cleared by its
/// teardown.
AccessibilityHost? platformAccessibility;
