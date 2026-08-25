/// A tiny ring of [DisplayList] arenas, so a frame producer can reuse one
/// instead of allocating a fresh encoder per frame.
///
/// ## Why a ring and not a single list
///
/// [DisplayList.reset] exists precisely so that a steady-state frame allocates
/// nothing: it rewinds the write cursors and keeps the two typed buffers,
/// which have already grown to the high-water mark of the content. A producer
/// that constructs a new [DisplayList] every frame throws that away twice
/// over - the object and its tables, and then the doubling walk back up to the
/// same capacity.
///
/// The obvious fix - one list, reset at the top of every frame - is wrong in
/// this repository, and not subtly. The retained CPU presenters
/// (`Win32CpuPresenter`, `X11CpuPresenter`, `WaylandCpuPresenter`) *keep* the
/// list they were handed and replay it into the replacement surface when the
/// window is resized or its DPI changes. `Win32CpuPresenter.renderDisplayList`
/// states the contract in its own doc comment:
///
/// > The list is retained so a replacement surface can be repainted after a
/// > resize or DPI transition. It must therefore not be reset or mutated until
/// > the next call. Frame producers that reuse one arena should alternate two
/// > display lists, which also prevents recording over a frame in flight.
///
/// So the list handed to a presenter has to survive until the *next*
/// presentation, not merely until the present call returns - which rules out
/// both a single reused list and a reset deferred to just after `present`.
/// Two alternating lists satisfy it exactly: the one being recorded is never
/// the one a presenter is holding, because [advance] is only called once the
/// current list has been handed over.
///
/// ## Why [advance] is separate from [current]
///
/// A frame is not one recording pass. `ApplicationWindow.drawFrame` runs a
/// settle loop that builds, lays out and paints up to eight times and presents
/// only the last result; a virtualized list legitimately needs two passes. If
/// the ring rotated per recording pass, an eight-pass frame would rotate four
/// times through a two-list ring and reset the list a presenter still holds.
///
/// Rotating on *presentation* instead is both correct and cheaper: every
/// discarded settle pass reuses the same arena - which is exactly right, since
/// those lists are thrown away - and the ring turns once per presented frame.
library;

import 'display_list.dart';

/// A fixed ring of [DisplayList]s owned by one frame producer.
///
/// Not thread safe and not meant to be: a producer is a single window's frame
/// pipeline, and Dart isolates do not share these.
final class DisplayListPool {
  /// Creates a pool of [size] lists.
  ///
  /// Two is the default because two is what the retained-presenter contract
  /// asks for; see the library comment. A larger ring is accepted for a
  /// backend that retains more than one frame, and costs one arena each.
  DisplayListPool({
    int size = 2,
    DisplayList Function()? createList,
  })  : assert(size > 0),
        _lists = List<DisplayList>.generate(
          size,
          (_) => createList == null ? DisplayList() : createList(),
          growable: false,
        );

  /// A pool of exactly one list, for a producer that presents nothing and
  /// therefore retains nothing - a test harness, or an offscreen renderer that
  /// consumes the list before it returns.
  DisplayListPool.single() : this(size: 1);

  final List<DisplayList> _lists;
  int _index = 0;
  int _rotations = 0;

  /// How many lists the ring holds.
  int get size => _lists.length;

  /// The list the next frame records into.
  ///
  /// The producer resets it; the pool never does, because only the producer
  /// knows when a recording pass begins.
  DisplayList get current => _lists[_index];

  /// The list at [index] in ring order, for tests that need to prove the ring
  /// actually alternates.
  DisplayList listAt(int index) => _lists[index];

  /// Which slot [current] is.
  int get index => _index;

  /// How many times [advance] has turned the ring. The observable proof that
  /// a settle loop does *not* rotate.
  int get rotations => _rotations;

  /// Turns the ring after the current list has been handed to a presenter.
  ///
  /// Call this once per *presented* frame, immediately after the present call
  /// returns - not once per recording pass. See the library comment for why
  /// the difference is the whole design.
  void advance() {
    _rotations++;
    if (_lists.length == 1) return;
    _index = _index + 1 == _lists.length ? 0 : _index + 1;
  }

  /// Rewinds every list in the ring and forgets which slot is current.
  ///
  /// For a producer that is shutting a window down, or a test that wants a
  /// fresh ring without new allocations. Never call it while a presenter still
  /// holds one of these lists.
  void resetAll() {
    for (var i = 0; i < _lists.length; i++) {
      _lists[i].reset();
    }
    _index = 0;
  }

  /// Total buffer reallocations across the ring.
  ///
  /// The number that proves the arena works: it stops increasing once every
  /// list in the ring has seen a full-sized frame.
  int get bufferGrowths {
    var total = 0;
    for (var i = 0; i < _lists.length; i++) {
      total += _lists[i].bufferGrowths;
    }
    return total;
  }
}
