/// A widget that flies from one screen to the next - Flutter's `Hero`.
///
/// Give the same [Hero.tag] to a widget on the screen being left and one on
/// the screen arriving, and while the route animates the navigator draws one
/// copy travelling from the first one's rectangle to the second's, both
/// originals hidden until it lands. A pop flies back the same way.
///
/// ## How the flight is found and measured
///
/// Every [Hero] registers itself under its route and tag as it builds. A
/// push or a pop that animates puts one entry on top of the navigator's
/// overlay, which is therefore laid out after the arriving route, whose
/// heroes have a position by then. A page is built while it is laid out,
/// so the flight matches its pairs in a builder that runs in layout too, by
/// which point every hero of both routes has registered. That ordering is
/// the whole timing model: no post-frame callback and no frame drawn before
/// the flight starts.
///
/// The flight goes to where the destination is *laid out*, not where a page
/// transition happens to paint it this frame - a sliding page arrives at
/// the rectangle the hero flies to.
///
/// What flies is the destination's child, as Flutter's default shuttle.
/// Heroes are matched within one navigator; a tag twice on one route is the
/// last one built.
library;

import '../animation/animation.dart';
import '../animation/curves.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import 'element.dart';
import 'layout_builder.dart';
import 'menu_anchor.dart' show AnchorProbe, MenuAnchorBox;
import 'overlay.dart';
import 'routes.dart';
import 'widget.dart';

/// Marks [child] as the same thing across two routes, by [tag].
final class Hero extends StatefulWidget {
  const Hero({super.key, required this.tag, required this.child});

  /// What matches this hero to the one on the other route.
  final Object tag;

  final Widget child;

  @override
  State<Hero> createState() => _HeroState();
}

/// Whether a hero is hidden because its copy is in the air, and the render
/// object that has to repaint when that changes.
final class _HideFlag {
  bool hidden = false;
  _RenderHeroHide? render;

  void set(bool value) {
    if (value == hidden) return;
    hidden = value;
    render?.markNeedsPaint();
  }
}

/// The heroes of each route, by tag.
final Expando<Map<Object, _HeroState>> _heroesOf =
    Expando<Map<Object, _HeroState>>();

final class _HeroState extends State<Hero> {
  final MenuAnchorBox _box = MenuAnchorBox();
  final _HideFlag _hide = _HideFlag();
  Route<Object?>? _route;
  Object? _tag;

  void _register(Route<Object?>? route) {
    if (identical(route, _route) && widget.tag == _tag) return;
    _unregister();
    _route = route;
    _tag = widget.tag;
    if (route == null) return;
    (_heroesOf[route] ??= <Object, _HeroState>{})[widget.tag] = this;
  }

  void _unregister() {
    final Route<Object?>? route = _route;
    final Object? tag = _tag;
    if (route == null || tag == null) return;
    final Map<Object, _HeroState>? heroes = _heroesOf[route];
    if (heroes != null && identical(heroes[tag], this)) heroes.remove(tag);
  }

  @override
  void dispose() {
    _unregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _register(Route.maybeOf(context));
    return _HeroHide(
      flag: _hide,
      child: AnchorProbe(anchor: _box, child: widget.child),
    );
  }
}

/// Starts the flights between [from] and [to], when the transition between
/// them animates: [push] says [to] is arriving, otherwise [from] is leaving
/// and [to] is the route under it. Called by the navigator.
void startHeroFlights({
  required OverlayState overlay,
  required Route<Object?> from,
  required Route<Object?> to,
  required bool push,
}) {
  final Animation<double> animation = push ? to.animation : from.animation;
  if (!animation.isAnimating) return;
  final Map<Object, _HeroState>? leaving = _heroesOf[from];
  if (leaving == null || leaving.isEmpty) return;
  late final OverlayEntry entry;
  final _Flights flights = _Flights(from, to, animation, push);
  entry = OverlayEntry(
    builder: (BuildContext context) => _FlightsWidget(flights: flights),
  );
  overlay.insert(entry);
  void landed(AnimationStatus status) {
    final bool done = push
        ? status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed
        : status == AnimationStatus.dismissed ||
            status == AnimationStatus.completed;
    if (!done) return;
    animation.removeStatusListener(landed);
    flights.land();
    if (entry.isInserted) entry.remove();
  }

  animation.addStatusListener(landed);
}

/// The pairs in the air for one transition.
final class _Flights {
  _Flights(this.from, this.to, this.animation, this.push);

  final Route<Object?> from;
  final Route<Object?> to;
  final Animation<double> animation;
  final bool push;

  final List<_HideFlag> _hidden = <_HideFlag>[];

  /// The pairs whose tag is on both routes, hiding both ends.
  List<(_HeroState, _HeroState)> pairs() {
    final Map<Object, _HeroState> leaving =
        _heroesOf[from] ?? const <Object, _HeroState>{};
    final Map<Object, _HeroState> arriving =
        _heroesOf[to] ?? const <Object, _HeroState>{};
    final List<(_HeroState, _HeroState)> found = <(_HeroState, _HeroState)>[];
    for (final MapEntry<Object, _HeroState> entry in leaving.entries) {
      final _HeroState? other = arriving[entry.key];
      if (other == null) continue;
      found.add((entry.value, other));
      for (final _HideFlag flag in <_HideFlag>[
        entry.value._hide,
        other._hide
      ]) {
        // Set during this entry's build: the heroes were built earlier in
        // the frame, and their paint, which is what hiding changes, is
        // still to come.
        flag.set(true);
        _hidden.add(flag);
      }
    }
    return found;
  }

  /// Progress from [from]'s hero to [to]'s, 0 to 1.
  double get progress {
    final double value = animation.value.clamp(0.0, 1.0);
    return Curves.fastOutSlowIn.transform(push ? value : 1 - value);
  }

  void land() {
    for (final _HideFlag flag in _hidden) {
      flag.set(false);
    }
    _hidden.clear();
  }
}

final class _FlightsWidget extends StatelessWidget {
  const _FlightsWidget({required this.flights});

  final _Flights flights;

  /// Built in layout, not in build: a route's page is itself built while it
  /// is laid out, so the arriving heroes exist only after the entries below
  /// this one have been laid out - which is exactly when a builder in
  /// layout runs.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final List<(_HeroState, _HeroState)> pairs = flights.pairs();
          return _FlightLayer(
            flights: flights,
            boxes: <(MenuAnchorBox, MenuAnchorBox)>[
              for (final (_HeroState a, _HeroState b) in pairs)
                (a._box, b._box),
            ],
            children: <Widget>[
              for (final (_, _HeroState b) in pairs) b.widget.child,
            ],
          );
        },
      );
}

final class _FlightLayer extends MultiChildRenderObjectWidget {
  const _FlightLayer({
    required this.flights,
    required this.boxes,
    required super.children,
  });

  final _Flights flights;
  final List<(MenuAnchorBox, MenuAnchorBox)> boxes;

  @override
  _RenderFlightLayer createRenderObject(BuildContext context) =>
      _RenderFlightLayer(flights, boxes);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderFlightLayer renderObject,
  ) =>
      renderObject.boxes = boxes;
}

/// Lays each flying copy out at the rectangle between its two heroes.
final class _RenderFlightLayer extends RenderBoxContainer<BoxParentData> {
  _RenderFlightLayer(this._flights, this.boxes) {
    _flights.animation.addListener(markNeedsLayout);
  }

  final _Flights _flights;
  List<(MenuAnchorBox, MenuAnchorBox)> boxes;

  @override
  void detach() {
    _flights.animation.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final Offset origin = localToGlobal(Offset.zero);
    final double t = _flights.progress;
    for (int i = 0; i < childCount && i < boxes.length; i++) {
      final RenderBox child = childAt(i);
      final Rect? from = boxes[i].$1.globalRect;
      final Rect? to = boxes[i].$2.globalRect;
      final Rect rect = from == null || to == null
          ? (to ?? from ?? Rect.zero)
          : Rect.lerp(from, to, t)!;
      child.layout(BoxConstraints.tight(Size(rect.width, rect.height)),
          parentUsesSize: true);
      child.parentData!.offset =
          Offset(rect.left - origin.dx, rect.top - origin.dy);
    }
  }

  /// A copy in the air takes no clicks: the screens under it are live.
  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) => null;

  @override
  bool hitTestSelf(Offset position) => false;
}

final class _HeroHide extends SingleChildRenderObjectWidget {
  const _HeroHide({required this.flag, super.child});

  final _HideFlag flag;

  @override
  _RenderHeroHide createRenderObject(BuildContext context) =>
      _RenderHeroHide(flag);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderHeroHide renderObject,
  ) =>
      renderObject.flag = flag;
}

/// Lays out and hit-tests as its child, and paints nothing while the
/// hero's copy is in the air.
final class _RenderHeroHide extends RenderSingleChildBox {
  _RenderHeroHide(this._flag) {
    _flag.render = this;
  }

  _HideFlag _flag;

  set flag(_HideFlag value) {
    if (identical(value, _flag)) return;
    _flag = value..render = this;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = child.size;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    if (_flag.hidden) return;
    super.paint(list, offset);
  }
}
