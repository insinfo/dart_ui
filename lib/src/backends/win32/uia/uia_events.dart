/// Turning a [SemanticsUpdate] into the events UI Automation wants (31.4).
///
/// Pure Dart, for the same reason `uia_mapping.dart` is: what a screen reader
/// is *told* changed is decided here, and it is testable everywhere. The layer
/// below only calls `UiaRaiseAutomationEvent`,
/// `UiaRaiseAutomationPropertyChangedEvent` and
/// `UiaRaiseStructureChangedEvent` with what this produces.
///
/// ## Why the diff is not forwarded one for one
///
/// [SemanticsUpdate] is a frame's worth of change. A window that opens, a list
/// that fills, a route that replaces another - each of those is one Dart update
/// and hundreds of nodes. UI Automation is a cross-process, marshalled channel:
/// every raised event is at minimum a round trip through UIAutomationCore and,
/// when a client is listening, an RPC. Forwarding a thousand `ChildAdded`s is
/// how a screen reader falls a second behind the UI.
///
/// So structural change collapses: past [UiaEventTranslator.bulkThreshold]
/// added-or-removed nodes the whole batch becomes a single
/// `StructureChangeType_ChildrenInvalidated` on the root, which is exactly the
/// message "re-read the subtree" and is what the platform's own controls send.
/// Property changes do not collapse, because each of them names a fact a
/// client may be watching for and there are never many in one frame.
library;

import '../../../semantics/semantics.dart';
import 'uia_constants.dart';
import 'uia_mapping.dart';

/// One thing to tell UI Automation about.
sealed class UiaEventRecord {
  const UiaEventRecord(this.nodeId);

  /// The semantic node the event is raised *on*. The layer below resolves it
  /// to a provider; a node that no longer has one is dropped there, not here.
  final int nodeId;
}

/// A plain `UiaRaiseAutomationEvent`.
final class UiaAutomationEventRecord extends UiaEventRecord {
  const UiaAutomationEventRecord(super.nodeId, this.eventId);

  /// A `UIA_*EventId`.
  final int eventId;

  @override
  bool operator ==(Object other) =>
      other is UiaAutomationEventRecord &&
      other.nodeId == nodeId &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(nodeId, eventId);

  @override
  String toString() => 'UiaAutomationEventRecord($nodeId, '
      '${uiaEventNames[eventId] ?? eventId})';
}

/// A `UiaRaiseAutomationPropertyChangedEvent`.
final class UiaPropertyChangedRecord extends UiaEventRecord {
  const UiaPropertyChangedRecord(
    super.nodeId, {
    required this.propertyId,
    required this.oldValue,
    required this.newValue,
  });

  /// A `UIA_*PropertyId`.
  final int propertyId;

  /// The Dart-side values, in the same vocabulary [uiaPropertiesFor] uses.
  /// Either may be null, which becomes `VT_EMPTY`.
  final Object? oldValue;
  final Object? newValue;

  @override
  bool operator ==(Object other) =>
      other is UiaPropertyChangedRecord &&
      other.nodeId == nodeId &&
      other.propertyId == propertyId &&
      other.oldValue == oldValue &&
      other.newValue == newValue;

  @override
  int get hashCode => Object.hash(nodeId, propertyId, oldValue, newValue);

  @override
  String toString() => 'UiaPropertyChangedRecord($nodeId, '
      '${uiaPropertyNames[propertyId] ?? propertyId}: '
      '$oldValue -> $newValue)';
}

/// A `UiaRaiseStructureChangedEvent`.
final class UiaStructureChangedRecord extends UiaEventRecord {
  const UiaStructureChangedRecord(
    super.nodeId, {
    required this.changeType,
    this.childRuntimeId,
  });

  /// A `StructureChangeType_*`.
  final int changeType;

  /// The runtime id of the child that came or went, for the two change types
  /// that name one. Null for the invalidating kinds, which name a subtree.
  ///
  /// Held as the semantic id rather than the full runtime id array, because
  /// the `UiaAppendRuntimeId` prefix belongs to the FFI layer that knows the
  /// window.
  final int? childRuntimeId;

  @override
  bool operator ==(Object other) =>
      other is UiaStructureChangedRecord &&
      other.nodeId == nodeId &&
      other.changeType == changeType &&
      other.childRuntimeId == childRuntimeId;

  @override
  int get hashCode => Object.hash(nodeId, changeType, childRuntimeId);

  @override
  String toString() => 'UiaStructureChangedRecord($nodeId, '
      'changeType $changeType, child $childRuntimeId)';
}

/// Translates a frame's [SemanticsUpdate] into [UiaEventRecord]s.
///
/// Stateless apart from its thresholds; the caller supplies the previous
/// snapshot, because [SemanticsOwner] has already replaced its own by the time
/// the update is in hand.
final class UiaEventTranslator {
  const UiaEventTranslator({
    this.bulkThreshold = 16,
    this.raiseBoundingRectangleChanges = false,
  });

  /// Past this many added-plus-removed nodes, structural change becomes one
  /// `ChildrenInvalidated` on the root instead of one event per node.
  final int bulkThreshold;

  /// Whether a moved or resized node raises a `BoundingRectangle` property
  /// change.
  ///
  /// **Off, and declared off rather than forgotten.** Every scroll and every
  /// window resize changes the rectangle of every node in the subtree, so this
  /// is the one property whose changes arrive by the hundred per frame, and
  /// each one costs two `VT_R8 | VT_ARRAY` SAFEARRAYs across a marshalled
  /// boundary. Microsoft's own guidance is that clients re-read the rectangle
  /// when they need it. A client that genuinely wants the notification can ask
  /// for it by constructing the translator with this set.
  final bool raiseBoundingRectangleChanges;

  /// Properties never diffed, whatever [raiseBoundingRectangleChanges] says.
  ///
  /// `RuntimeId` cannot change without the node being a different node, and
  /// `AutomationId` and `FrameworkId` are derived from the id and from a
  /// constant. Diffing them would only cost time.
  static const Set<int> _neverDiffed = <int>{
    uiaRuntimeIdPropertyId,
    uiaAutomationIdPropertyId,
    uiaFrameworkIdPropertyId,
  };

  /// The events for [update], given the tree as it was in [before].
  ///
  /// [before] may be null on the first publish, in which case everything is an
  /// addition and the result is the single "re-read everything" event.
  List<UiaEventRecord> translate(
    SemanticsUpdate update, {
    SemanticsSnapshot? before,
    SemanticsSnapshot? after,
  }) {
    if (update.isEmpty) return const <UiaEventRecord>[];

    final List<UiaEventRecord> events = <UiaEventRecord>[];
    final Map<int, SemanticsNode> previous = <int, SemanticsNode>{
      for (final SemanticsNode node in before?.nodes ?? const <SemanticsNode>[])
        node.id: node,
    };

    // ---- structure -------------------------------------------------------
    final int structuralCount = update.added.length + update.removed.length;
    final int rootId = after?.root?.id ?? before?.root?.id ?? 0;
    if (structuralCount > bulkThreshold) {
      events.add(
        UiaStructureChangedRecord(
          rootId,
          changeType: structureChangeTypeChildrenInvalidated,
        ),
      );
    } else {
      for (final SemanticsNode node in update.added) {
        // ChildAdded is raised *on the child*, which is what UI Automation
        // documents and what lets a client fetch it without walking.
        events.add(
          UiaStructureChangedRecord(
            node.id,
            changeType: structureChangeTypeChildAdded,
            childRuntimeId: node.id,
          ),
        );
      }
      final Set<int> removedIds = update.removed.toSet();
      for (final int removed in update.removed) {
        // ChildRemoved has to be raised on something that still exists, so it
        // goes to the parent the node had - or to the root when the parent
        // went with it. Checking the parent against the *removed* set and not
        // against the previous tree is the point: a whole subtree leaving at
        // once would otherwise address half its events to nodes that left in
        // the same frame, and UI Automation drops those without a word.
        final int? parent = _parentOf(removed, before);
        events.add(
          UiaStructureChangedRecord(
            parent == null || removedIds.contains(parent) ? rootId : parent,
            changeType: structureChangeTypeChildRemoved,
            childRuntimeId: removed,
          ),
        );
      }
    }

    // ---- properties ------------------------------------------------------
    for (final SemanticsNode node in update.updated) {
      final SemanticsNode? old = previous[node.id];
      if (old == null) continue;
      final Map<int, Object?> oldProperties = uiaPropertiesFor(old);
      final Map<int, Object?> newProperties = uiaPropertiesFor(node);

      final Set<int> ids = <int>{...oldProperties.keys, ...newProperties.keys};
      for (final int id in ids) {
        if (_neverDiffed.contains(id)) continue;
        if (id == uiaBoundingRectanglePropertyId &&
            !raiseBoundingRectangleChanges) {
          continue;
        }
        final Object? oldValue = oldProperties[id];
        final Object? newValue = newProperties[id];
        if (_sameValue(oldValue, newValue)) continue;
        events.add(
          UiaPropertyChangedRecord(
            node.id,
            propertyId: id,
            oldValue: oldValue,
            newValue: newValue,
          ),
        );
      }

      // Focus is its own event as well as a property, and the *event* is the
      // one screen readers act on: it is what moves the reading cursor.
      final bool hadFocus = old.states.contains(SemanticsState.focused);
      final bool hasFocus = node.states.contains(SemanticsState.focused);
      if (!hadFocus && hasFocus) {
        events.add(
          UiaAutomationEventRecord(
            node.id,
            uiaAutomationFocusChangedEventId,
          ),
        );
      }
    }

    // A node that appears already focused - a dialog that opens with focus in
    // it - never shows up in `updated`, so the focus event has to come from
    // the added list too.
    for (final SemanticsNode node in update.added) {
      if (node.states.contains(SemanticsState.focused)) {
        events.add(
          UiaAutomationEventRecord(
            node.id,
            uiaAutomationFocusChangedEventId,
          ),
        );
      }
      if (node.role == SemanticsRole.tooltip) {
        events.add(
          UiaAutomationEventRecord(node.id, uiaToolTipOpenedEventId),
        );
      }
      if (node.role == SemanticsRole.menu) {
        events.add(UiaAutomationEventRecord(node.id, uiaMenuOpenedEventId));
      }
    }

    return events;
  }

  /// The id of the node that had [childId] as a child in [snapshot].
  static int? _parentOf(int childId, SemanticsSnapshot? snapshot) {
    final SemanticsNode? root = snapshot?.root;
    if (root == null) return null;
    for (final SemanticsNode node in root.flattened) {
      for (final SemanticsNode child in node.children) {
        if (child.id == childId) return node.id;
      }
    }
    return null;
  }

  /// Value equality that also handles the `List<double>` a rectangle is.
  static bool _sameValue(Object? a, Object? b) {
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return a == b;
  }
}
