/// Blocking synchronisation between isolates, over the platform's own
/// primitives.
///
/// Dart's own handoff between isolates is a `SendPort`, and a `SendPort` is
/// asynchronous by construction: the receiver learns about a message when its
/// event loop next runs, behind every timer, every I/O completion and every
/// rebuild already queued. For a decoder feeding a renderer at twenty-five
/// frames a second that is latency nobody asked for and jitter nobody can
/// bound.
///
/// This layer adds the missing operation - **park this thread until the other
/// isolate says otherwise** - built on `SRWLOCK` + `CONDITION_VARIABLE` on
/// Windows and `pthread_mutex_t` + `pthread_cond_t` on POSIX. Nothing in it is
/// asynchronous and nothing in it goes through the event loop.
///
/// ## What it does not do
///
/// It does not make video faster. The frame rate of the player is bounded by
/// CPU colour conversion, not by the handoff: the memory question was already
/// settled by `NativeVideoFrameRing` (a shared native ring measured at 1.10x a
/// single-isolate baseline, against 3.47x for a port copy and 4.82x for
/// `TransferableTypedData`). What this buys is *latency* and independence from
/// the event loop, not throughput.
///
/// ## Read this before using [BlockingSlotMailbox.takeBlocking]
///
/// A blocking take on the isolate that services the UI freezes the application
/// completely - the same failure as the Win32 modal loop in section 68.4.4 of
/// the roadmap. Every method here that can park refuses to run on the root
/// isolate. See [BlockingWaitPolicy].
library;

export 'blocking_byte_mailbox.dart';
export 'blocking_slot_mailbox.dart';
export 'blocking_wait.dart';
export 'native_condition_variable.dart';
export 'native_mutex.dart';
export 'native_sync_bindings.dart';
