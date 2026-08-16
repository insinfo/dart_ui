/// Gesture disambiguation: one pointer, several claimants, exactly one winner.
///
/// The problem the arena solves cannot be solved locally. A press on a button
/// inside a scrollable list is, at the instant it arrives, indistinguishable
/// from the first millisecond of a scroll. Neither the button nor the list can
/// decide alone: the button would have to know it is inside a list, and the
/// list would have to know it contains a button. What decides is *what happens
/// next* - and something has to hold both interpretations open until then,
/// then tell the loser it lost.
///
/// That is the whole of this file. An arena exists per pointer, from the press
/// until the gesture resolves. Members join while it is open, and leave with
/// exactly one of [GestureArenaMember.acceptGesture] or
/// [GestureArenaMember.rejectGesture] - never both, never neither. Two rules
/// pick the winner:
///
///  * **the first member to claim victory wins.** A recognizer that has seen
///    enough - a drag past the slop, a long press past its deadline - takes the
///    gesture and everyone else is told to stop;
///  * **the last member standing wins by walkover.** If nobody claims, then as
///    soon as only one candidate remains it wins for free. This is what makes a
///    lone tap detector fire without having to know it is alone.
///
/// The design is Flutter's, whose gesture arena is the reference
/// implementation of this model; the code is not.
library;

/// The two ways a member can leave an arena.
enum GestureDisposition {
  /// This member's interpretation is the right one. Everyone else loses.
  accepted,

  /// This member is out. It is told immediately, and no longer counts toward
  /// the walkover.
  rejected,
}

/// Anything that can win or lose a gesture negotiation.
///
/// Exactly one of the two methods is called for each arena the member joined,
/// whatever caused the resolution - including a member resolving in its own
/// favour, which still gets its [acceptGesture] call. Recognizers rely on that
/// symmetry to release state in one place instead of two.
abstract interface class GestureArenaMember {
  /// This member won the arena for [pointer].
  void acceptGesture(int pointer);

  /// This member lost the arena for [pointer].
  void rejectGesture(int pointer);
}

/// One member's seat in one pointer's arena.
///
/// Handed back by [GestureArenaManager.add]. A member keeps it so it can
/// concede or claim later, from a timer or from a subsequent event, without
/// having to remember which manager and which pointer it belonged to.
final class GestureArenaEntry {
  GestureArenaEntry._(this._arena, this._pointer, this._member);

  final GestureArenaManager _arena;
  final int _pointer;
  final GestureArenaMember _member;

  /// Which pointer this seat is for.
  int get pointer => _pointer;

  /// Claims victory ([GestureDisposition.accepted]) or concedes
  /// ([GestureDisposition.rejected]).
  ///
  /// Harmless on an arena that has already resolved, which matters because a
  /// timer armed before the resolution will still fire after it.
  void resolve(GestureDisposition disposition) =>
      _arena._resolve(_pointer, _member, disposition);
}

/// The mutable state of one pointer's arena. Private: a member sees only its
/// own [GestureArenaEntry].
final class _Arena {
  final List<GestureArenaMember> members = <GestureArenaMember>[];

  /// True until the press has finished being offered to the whole hit-test
  /// path. While open, nobody can win: a deeper member that has not been
  /// offered the event yet would lose a race it never entered.
  bool isOpen = true;

  /// True while a member has asked for the sweep to be postponed.
  bool isHeld = false;

  /// True when a sweep arrived during a hold and still owes a resolution.
  bool hasPendingSweep = false;

  /// The member that claimed victory while the arena was still open.
  ///
  /// It cannot be granted the win yet - see [isOpen] - so the claim is parked
  /// here and honoured the moment the arena closes. Only the first claimant is
  /// kept; a second one is not more deserving for having also been early.
  GestureArenaMember? eagerWinner;

  @override
  String toString() => '_Arena(${members.length} member(s)'
      '${isOpen ? ', open' : ''}${isHeld ? ', held' : ''})';
}

/// Owns one arena per live pointer.
///
/// One instance per window is the intended scale - it is held by
/// `PointerRouter`, which is itself per render tree - so two windows never
/// share arena state for the same platform pointer id.
final class GestureArenaManager {
  final Map<int, _Arena> _arenas = <int, _Arena>{};

  /// How many pointers currently have an unresolved arena. Zero between
  /// gestures; a number that only grows is the signature of a leak.
  int get openArenaCount => _arenas.length;

  /// Whether [pointer] has an arena at all.
  bool hasArena(int pointer) => _arenas.containsKey(pointer);

  /// Whether [pointer]'s arena is still accepting members.
  bool isOpen(int pointer) => _arenas[pointer]?.isOpen ?? false;

  /// How many members are still in the running for [pointer].
  int memberCount(int pointer) => _arenas[pointer]?.members.length ?? 0;

  /// Seats [member] in [pointer]'s arena, opening one if needed.
  ///
  /// Order of entry is the tie-break for the walkover and for [sweep], and the
  /// order is deepest-first because that is the order the hit-test path
  /// dispatches in. That single fact is what makes an inner recognizer beat an
  /// outer one when neither has better evidence.
  GestureArenaEntry add(int pointer, GestureArenaMember member) {
    final _Arena state = _arenas.putIfAbsent(pointer, _Arena.new);
    if (!state.isOpen) {
      throw StateError(
        'GestureArenaManager.add() was called for pointer $pointer after its '
        'arena closed. A recognizer may only join while the press is still '
        'being offered to the hit-test path; joining later would let it win '
        'a negotiation the other members already finished.',
      );
    }
    state.members.add(member);
    return GestureArenaEntry._(this, pointer, member);
  }

  /// Stops new members joining, and resolves if the outcome is already
  /// determined.
  ///
  /// Called once the press has been offered to every target in the hit-test
  /// path. Two things can be settled here: an eager claim parked during the
  /// open phase, and a walkover when only one candidate ever joined.
  ///
  /// **The walkover is synchronous**, unlike Flutter's, which defers it to a
  /// microtask. The microtask exists there to put the default win after the
  /// rest of the down-event dispatch; here the caller is required to call
  /// [close] *after* that dispatch, which buys the same ordering without
  /// making the outcome depend on the async scheduler. A framework whose test
  /// suite runs on a virtual clock cannot afford a resolution that lands in a
  /// microtask, because then "did the tap fire?" depends on whether the test
  /// happened to await anything.
  void close(int pointer) {
    final _Arena? state = _arenas[pointer];
    if (state == null) return;
    state.isOpen = false;
    _tryToResolve(pointer, state);
  }

  /// Forces a decision: the first remaining member wins.
  ///
  /// Called after the release has been dispatched. Without it, two passive
  /// recognizers that each politely wait for the other would deadlock and the
  /// user's tap would simply do nothing - the failure mode that makes an arena
  /// feel broken rather than merely undecided.
  ///
  /// A [hold] postpones this; the sweep is remembered and performed by
  /// [release].
  void sweep(int pointer) {
    final _Arena? state = _arenas[pointer];
    if (state == null) return;
    if (state.isOpen) {
      throw StateError(
        'GestureArenaManager.sweep() was called for pointer $pointer while '
        'its arena was still open. Close it first: sweeping an open arena '
        'would decide a negotiation that some members have not yet joined.',
      );
    }
    if (state.isHeld) {
      state.hasPendingSweep = true;
      return;
    }
    _arenas.remove(pointer);
    if (state.members.isEmpty) return;
    final GestureArenaMember winner = state.members.first;
    for (var i = 1; i < state.members.length; i++) {
      state.members[i].rejectGesture(pointer);
    }
    winner.acceptGesture(pointer);
  }

  /// Ends [pointer]'s arena with **no** winner, rejecting everyone left.
  ///
  /// This is the answer to a cancelled pointer - a lost mouse capture, a window
  /// deactivated mid-drag, a touch the compositor took away - and it is
  /// deliberately not the same as [sweep]. A cancel is the input going away,
  /// not the user finishing; awarding the gesture to somebody would fire an
  /// `onTap` for a press that was never released.
  ///
  /// It also has to be unconditional, which is why a [hold] does not postpone
  /// it: a recognizer holding the arena open for a second tap that can no
  /// longer arrive would keep the arena - and every member's state with it -
  /// alive forever. An arena left pending is not a stalled gesture, it is a
  /// leak that silently swallows the next press on the same pointer id, and
  /// the window stops responding with nothing in the logs.
  void cancel(int pointer) {
    final _Arena? state = _arenas.remove(pointer);
    if (state == null) return;
    for (final GestureArenaMember member in state.members) {
      member.rejectGesture(pointer);
    }
  }

  /// Postpones [sweep] for [pointer] until [release].
  ///
  /// For a recognizer whose decision outlives the release - a double tap
  /// waiting to see whether a second press arrives.
  void hold(int pointer) {
    final _Arena? state = _arenas[pointer];
    if (state == null) return;
    state.isHeld = true;
  }

  /// Ends a [hold], performing the sweep it postponed if one arrived.
  void release(int pointer) {
    final _Arena? state = _arenas[pointer];
    if (state == null) return;
    state.isHeld = false;
    if (state.hasPendingSweep) {
      sweep(pointer);
    } else if (!state.isOpen) {
      // A walkover suppressed during the hold is owed as soon as it ends.
      _tryToResolve(pointer, state);
    }
  }

  void _resolve(
    int pointer,
    GestureArenaMember member,
    GestureDisposition disposition,
  ) {
    final _Arena? state = _arenas[pointer];
    if (state == null) return; // Already resolved; a late claim is a no-op.
    switch (disposition) {
      case GestureDisposition.accepted:
        if (state.isOpen) {
          state.eagerWinner ??= member;
        } else {
          _resolveInFavorOf(pointer, state, member);
        }
      case GestureDisposition.rejected:
        if (identical(state.eagerWinner, member)) state.eagerWinner = null;
        if (!state.members.remove(member)) return;
        member.rejectGesture(pointer);
        if (!state.isOpen) _tryToResolve(pointer, state);
    }
  }

  void _tryToResolve(int pointer, _Arena state) {
    final GestureArenaMember? eager = state.eagerWinner;
    if (eager != null) {
      _resolveInFavorOf(pointer, state, eager);
      return;
    }
    if (state.members.isEmpty) {
      _arenas.remove(pointer);
      return;
    }
    // The walkover: one candidate left and nobody to argue with it.
    if (state.members.length == 1 && !state.isHeld) {
      final GestureArenaMember winner = state.members.first;
      _arenas.remove(pointer);
      winner.acceptGesture(pointer);
    }
  }

  void _resolveInFavorOf(
    int pointer,
    _Arena state,
    GestureArenaMember member,
  ) {
    _arenas.remove(pointer);
    for (final GestureArenaMember other in state.members) {
      if (!identical(other, member)) other.rejectGesture(pointer);
    }
    member.acceptGesture(pointer);
  }
}
