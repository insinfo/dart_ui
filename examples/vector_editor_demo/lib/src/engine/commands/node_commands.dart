/// Nodes and paths: what CorelDRAW's Shape tool property bar does to the
/// nodes picked on a curve.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import 'command_context.dart';

List<CommandSpec> nodeCommands(EditorContext context) {
  final EditorModel model = context.model;

  /// The curve the Shape tool edits, or null.
  VectorCurve? curve() =>
      model.hasDocument ? model.selection.syncNodeCurve() : null;

  Set<PathNode> picked() => model.selection.nodes.nodes;

  String? needsCurve(CommandArgs args) =>
      context.needsDocument(args) ??
      (curve() == null ? 'select one curve (Convert to Curves first)' : null);

  String? needsNodes(CommandArgs args) =>
      needsCurve(args) ??
      (picked().isEmpty ? 'pick nodes with the Shape tool (F10)' : null);

  /// Runs [change] on the edited curve as one undo step named [label].
  Object? onCurve(String label, void Function(VectorCurve curve) change) {
    final VectorCurve target = curve()!;
    model.edit(label, () {
      change(target);
      model.selection.nodes.prune();
    });
    return <String, Object?>{'nodes': picked().length};
  }

  CommandSpec nodeCommand(
    String id,
    String label,
    void Function(VectorCurve curve, Set<PathNode> nodes) change, {
    String description = '',
    KeyGesture? shortcut,
    String? Function(CommandArgs)? when,
  }) =>
      CommandSpec(
        id: id,
        label: label,
        description: description,
        shortcut: shortcut,
        when: when ?? needsNodes,
        run: (_) => onCurve(label, (VectorCurve c) => change(c, picked())),
      );

  return <CommandSpec>[
    CommandSpec(
      id: 'path.selectAllNodes',
      label: 'Select all nodes',
      when: needsCurve,
      run: (_) {
        model.selection.nodes.selectAll();
        model.refresh('${picked().length} nodes selected');
        return <String, Object?>{'nodes': picked().length};
      },
    ),
    nodeCommand(
      'path.addNode',
      'Add node',
      (VectorCurve c, Set<PathNode> nodes) {
        // CorelDRAW adds a node halfway along the segment arriving at each
        // picked node; the later ones first, so earlier indices hold.
        final List<PathNode> sorted = nodes.toList()
          ..sort((PathNode a, PathNode b) => a.path != b.path
              ? b.path.compareTo(a.path)
              : b.index.compareTo(a.index));
        for (final PathNode node in sorted) {
          if (node.index == 0) continue;
          NodeEditing.insertNode(c, SegmentHit(node.path, node.index - 1, .5));
        }
      },
      description: 'Adds a node halfway along the segment before each picked '
          'node.',
    ),
    nodeCommand(
      'path.deleteNodes',
      'Delete nodes',
      (VectorCurve c, Set<PathNode> nodes) {
        if (!NodeEditing.deleteNodes(c, nodes)) {
          // Nothing of the curve is left: the object goes too.
          model.active.api.methods.removeObject(c);
          model.selection.deselectAll();
        }
        model.selection.nodes.clearNodes();
      },
      shortcut: platformEditingConvention == EditingConvention.mac
          ? const KeyGesture(logicalKeyBackspace)
          : const KeyGesture(logicalKeyDelete),
    ),
    nodeCommand('path.toLine', 'Convert segments to line',
        (VectorCurve c, Set<PathNode> nodes) => NodeEditing.toLine(c, nodes)),
    nodeCommand('path.toCurve', 'Convert segments to curve',
        (VectorCurve c, Set<PathNode> nodes) => NodeEditing.toCurve(c, nodes)),
    for (final (String id, String label, NodeType type)
        in <(String, String, NodeType)>[
      ('path.cusp', 'Cusp nodes', NodeType.cusp),
      ('path.smooth', 'Smooth nodes', NodeType.smooth),
      ('path.symmetrical', 'Symmetrical nodes', NodeType.symmetrical),
    ])
      nodeCommand(id, label, (VectorCurve c, Set<PathNode> nodes) {
        NodeEditing.toCurve(c, nodes);
        NodeEditing.setType(c, nodes, type);
      }),
    nodeCommand(
      'path.breakNode',
      'Break curve',
      (VectorCurve c, Set<PathNode> nodes) {
        final List<PathNode> ends = <PathNode>[];
        for (final PathNode node in nodes.toList().reversed) {
          ends.addAll(NodeEditing.breakAt(c, node));
        }
        model.selection.nodes.select(ends);
      },
      description: 'Opens the path at each picked node.',
    ),
    nodeCommand(
      'path.joinNodes',
      'Join two nodes',
      (VectorCurve c, Set<PathNode> nodes) {
        final List<PathNode> two = nodes.toList();
        if (!NodeEditing.join(c, two[0], two[1])) {
          throw const CommandError('pick the two end nodes of open paths');
        }
        model.selection.nodes.clearNodes();
      },
      when: (CommandArgs args) =>
          needsNodes(args) ??
          (picked().length == 2 ? null : 'pick exactly two end nodes'),
    ),
    CommandSpec(
      id: 'path.reverse',
      label: 'Reverse all paths',
      when: needsCurve,
      run: (_) => onCurve('Reverse paths',
          (VectorCurve c) => NodeEditing.reverse(c, const <PathNode>[])),
    ),
    CommandSpec(
      id: 'path.close',
      label: 'Close curve',
      when: needsCurve,
      run: (_) => onCurve('Close curve',
          (VectorCurve c) => NodeEditing.close(c, const <PathNode>[])),
    ),
  ];
}
