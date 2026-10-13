/// Shaping: CorelDRAW's Weld, Trim and Intersect, on the selected outlines.
///
/// The target - the object that is changed, and whose style the result
/// wears - is the last one selected, as in CorelDRAW.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import 'command_context.dart';

List<CommandSpec> shapingCommands(EditorContext context) {
  final EditorModel model = context.model;
  final String? Function(CommandArgs) twoOutlines = context.selectionThat(
      () => model.canShape, 'select two or more objects with an outline');

  Object? described(VectorCurve? curve) => curve == null
      ? null
      : <String, Object?>{'index': context.layerObjects.indexOf(curve)};

  return <CommandSpec>[
    CommandSpec(
      id: 'object.weld',
      label: 'Weld',
      description: 'Joins the selected outlines into one curve, in the place '
          'and style of the last one selected.',
      when: twoOutlines,
      run: (_) => described(model.weldSelection()),
    ),
    CommandSpec(
      id: 'object.trim',
      label: 'Trim',
      description: 'Cuts the other selected outlines out of the last one '
          'selected; they stay.',
      when: twoOutlines,
      run: (_) => described(model.trimSelection()),
    ),
    CommandSpec(
      id: 'object.intersect',
      label: 'Intersect',
      description: 'Makes a new curve where the selected outlines overlap, in '
          'the style of the last one selected.',
      when: twoOutlines,
      run: (_) {
        final VectorCurve? curve = model.intersectSelection();
        if (curve == null) {
          throw const CommandError('the selected objects do not overlap');
        }
        return described(curve);
      },
    ),
  ];
}
