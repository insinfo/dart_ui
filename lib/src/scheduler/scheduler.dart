/// The scheduler layer: the dispatcher contract of section 9.4 of the
/// roadmap, plus the deterministic implementation the rest of the framework
/// is tested against.
///
/// A backend supplies its own [UiDispatcher]; everything above the backend
/// depends only on this contract, which is why the widget, layout and render
/// layers can be exercised headlessly with a [ManualDispatcher] and no
/// window, no GPU and no clock.
library;

export 'dispatcher_priority.dart';
export 'frame_scheduler.dart';
export 'manual_dispatcher.dart';
export 'timer_handle.dart';
export 'ui_dispatcher.dart';
