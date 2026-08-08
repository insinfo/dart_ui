/// Dispatcher priorities, per section 9.4 of the roadmap.
///
/// The order below is not a preference list, it is the shape of one frame.
/// A frame that runs its stages out of order does not merely run slower - it
/// produces a *wrong* frame, and the wrongness is invisible in a screenshot
/// because every individual stage did its job correctly.
///
/// Reading top to bottom: input mutates state, animation mutates state as a
/// function of the frame time, layout consumes both, render consumes layout.
/// Every inversion of that chain costs either a frame of latency or a second
/// pass over work that was already done.
library;

/// The order in which a [UiDispatcher] is allowed to run pending work.
///
/// Values are declared most urgent first, so [index] *rises* as urgency
/// *falls*. That inversion is deliberate - it lets a dispatcher keep one
/// queue per priority in a plain list indexed by [index] and scan it forwards
/// - but it is also the easiest thing in this file to get backwards, so
/// prefer [isMoreUrgentThan] and [compareTo] over raw index arithmetic.
///
/// [compareTo] orders ascending in *dispatch* order: sorting a list of
/// priorities with the default comparator yields the order the dispatcher
/// will run them in.
enum DispatcherPriority implements Comparable<DispatcherPriority> {
  /// Above the frame pipeline entirely.
  ///
  /// Reserved for work the platform is synchronously waiting on: a resize
  /// acknowledgement, a teardown step, a reply a native callback needs before
  /// it returns. Anything queued here delays the next frame, so a control
  /// that reaches for [immediate] to "make it feel faster" is a bug.
  immediate,

  /// Delivery of pointer, keyboard, scroll and IME events into the tree.
  ///
  /// First of the frame stages because input is what makes the frame
  /// *current*. Draining input after animation would compute the frame from
  /// state that is one event older than what the user already did, which is
  /// exactly the input latency users perceive as a sluggish UI.
  input,

  /// Animation ticks driven by the frame clock.
  ///
  /// After [input] because an animation reads the same properties input just
  /// wrote; ticking first means computing from stale state and then having
  /// input overwrite it in the same frame. Before [layout] because an
  /// animated value is a layout input.
  animation,

  /// Constraint solving, measuring and positioning.
  ///
  /// After [input] and [animation] because it consumes what they produced.
  /// A layout scheduled before them is guaranteed to be invalidated and run
  /// twice in the same frame.
  layout,

  /// Display-list building and submission.
  ///
  /// Last of the frame stages because it consumes finished geometry. Nothing
  /// that can dirty layout may run after it, or the frame presents geometry
  /// that disagrees with the state that produced it.
  render,

  /// Application work with no frame deadline: callbacks, futures resolved by
  /// the UI isolate, model updates that are not driving the current frame.
  ///
  /// The default for [UiDispatcher.post], and the right answer whenever the
  /// caller cannot name a frame stage the work belongs to.
  normal,

  /// Work that runs only when nothing else is pending.
  ///
  /// May be starved indefinitely, by design. Suitable for cache trimming,
  /// prefetching and diagnostics; never for anything a user is waiting on.
  idle;

  /// The priority [UiDispatcher.post] assumes when the caller does not name
  /// one. Named so that implementations agree on it rather than each
  /// repeating a literal in their own signature.
  static const DispatcherPriority defaultPriority = normal;

  /// Whether the dispatcher runs work at this priority before work at
  /// [other], with everything else being equal.
  bool isMoreUrgentThan(DispatcherPriority other) => index < other.index;

  /// Whether the dispatcher runs work at this priority after work at [other],
  /// with everything else being equal.
  bool isLessUrgentThan(DispatcherPriority other) => index > other.index;

  @override
  int compareTo(DispatcherPriority other) => index.compareTo(other.index);
}
