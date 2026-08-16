/// The numbers a gesture is allowed to argue about, in one place.
///
/// Every constant here is a *threshold*, and a threshold is a policy decision
/// that has to be defensible or it becomes folklore. Each one below therefore
/// states where the number comes from and what breaks on either side of it.
library;

import '../platform/input_events.dart';

/// How far a **finger** may travel before the movement stops being a tap and
/// starts being a drag.
///
/// 18 logical pixels. Not a guess: a fingertip contact patch is roughly 9 mm
/// across and the reported position wanders inside it while the finger flattens
/// under pressure, so a threshold small enough to be "precise" simply means no
/// tap ever survives contact. Android's `ViewConfiguration` and Flutter both
/// arrived at 18 the same way - both started near 8 and raised it after users
/// reported that buttons were hard to hit.
///
/// This is a *hysteresis boundary between two interpretations*, not a dead
/// zone: below it the press is still a candidate tap, above it the press is
/// committed to being a drag and the tap gives up. See
/// [touchSlopForKind] for why a mouse gets a different number.
const double kTouchSlop = 18.0;

/// The same boundary for a **mouse or stylus**, which do not wander.
///
/// 4 logical pixels, which is Win32's `SM_CXDRAG`/`SM_CYDRAG` default - the
/// number the OS itself uses to decide that a button-down followed by motion
/// is a drag rather than a click. It also matches the 4-pixel multi-click slop
/// this repository already applies to mouse presses in
/// `RenderTextField._countClick`, so a press that counts as "the same spot"
/// for double-click purposes also counts as "did not move" for drag purposes.
///
/// Using [kTouchSlop] for a mouse would be actively wrong: 18 pixels of mouse
/// travel is a deliberate drag by any user's reckoning, and swallowing it
/// makes short drags - a 10-pixel nudge of a slider, selecting three
/// characters of text - impossible.
const double kPrecisePointerSlop = 4.0;

/// The slop that applies to [kind].
///
/// Touch gets [kTouchSlop]; everything else gets [kPrecisePointerSlop]. Stylus
/// is grouped with the mouse because a pen tip reports a single contact point
/// with sub-pixel resolution, which is the property that matters here.
double touchSlopForKind(PointerKind kind) =>
    kind == PointerKind.touch ? kTouchSlop : kPrecisePointerSlop;

/// The slop for a **two-dimensional** drag, which is twice the linear one.
///
/// A one-axis drag only has to prove motion along its own axis, and the other
/// axis is evidence *against* it. A pan has no such counter-evidence: any
/// motion at all is motion it would accept, so it wins arenas on noise unless
/// it is asked for more. Doubling is the cheapest way to say "a pan must be
/// more obviously deliberate than an axis drag", and it is what keeps a pan
/// nested inside a vertical list from stealing every scroll.
double panSlopForKind(PointerKind kind) => touchSlopForKind(kind) * 2.0;

/// How far the distance *between two pointers* must change to mean a pinch.
///
/// The same magnitude as the linear slop: a span is a distance, measured in the
/// same pixels, and a pinch that has moved the fingers further apart than one
/// finger's own jitter is a real pinch.
double scaleSlopForKind(PointerKind kind) => touchSlopForKind(kind);

/// How long a press must be held, motionless, to become a long press.
///
/// 500 ms, matching Android's `ViewConfiguration.getLongPressTimeout` and the
/// Windows touch press-and-hold delay. Shorter and an ordinary tap on a slow
/// finger turns into a context menu; longer and users let go first and conclude
/// the gesture does not exist.
const Duration kLongPressTimeout = Duration(milliseconds: 500);

/// The longest gap between two presses that still makes them one double tap.
///
/// **500 ms, deliberately equal to the Win32 `GetDoubleClickTime()` default**
/// and to `RenderTextField._multiClickInterval` in this repository, rather than
/// the 300 ms mobile toolkits use. Two reasons, in order of importance:
///
///  1. This value is only ever consulted when the platform did *not* count the
///     press for us - see [PointerDownEvent.clickCount]. On Windows it usually
///     did, using the interval from the user's mouse control panel, which is an
///     accessibility setting a person with a tremor genuinely raises. The
///     fallback must not be visibly stricter than the setting it stands in for.
///  2. Disagreeing with `_countClick` would mean the same two presses are a
///     double click for a text field and two single taps for a gesture
///     detector, in the same window, at the same instant.
const Duration kDoubleTapTimeout = Duration(milliseconds: 500);

/// The shortest gap that can still be two presses rather than one bounce.
///
/// 40 ms. Below this the second "press" is contact bounce or a hardware repeat,
/// not a human tapping twice; no one taps 25 times a second.
const Duration kDoubleTapMinTime = Duration(milliseconds: 40);

/// How far apart two presses may be and still be one double tap, by finger.
///
/// 100 pixels, far larger than [kTouchSlop], because the two taps are separate
/// contacts: the finger leaves the glass and comes back, and it lands where the
/// user was *looking*, not where the previous contact patch happened to
/// centre.
const double kTouchDoubleTapSlop = 100.0;

/// The same distance for a mouse: `SM_CXDOUBLECLK`'s default, 4 pixels.
///
/// A mouse does not leave the surface between clicks, so two clicks more than a
/// few pixels apart are two deliberate clicks at two targets.
const double kPreciseDoubleTapSlop = 4.0;

/// The double-tap distance that applies to [kind].
double doubleTapSlopForKind(PointerKind kind) =>
    kind == PointerKind.touch ? kTouchDoubleTapSlop : kPreciseDoubleTapSlop;

/// Below this speed a release is a stop, not a fling.
///
/// 50 logical pixels per second. A finger coming to rest still reports a few
/// pixels of motion in its last samples; handing that to
/// `ScrollPosition.fling` would make every drag end with a visible twitch.
const double kMinFlingVelocity = 50.0;

/// Above this speed a fling is clamped.
///
/// 8000 logical pixels per second is already a full screen every two frames.
/// The clamp exists because velocity is an *extrapolation*: two samples 1 ms
/// apart across a 40-pixel jump extrapolate to 40 000 px/s, and a momentum
/// simulation fed that number teleports.
const double kMaxFlingVelocity = 8000.0;
