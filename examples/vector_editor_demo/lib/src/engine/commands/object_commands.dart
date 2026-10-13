/// Object: structure (group, combine, curves), transformation (rotate,
/// flip, move, resize, nudge) and paint (fill, outline).
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import 'command_context.dart';

const CommandParam _color = CommandParam(
  'color',
  CommandParamType.any,
  required: true,
  description: '"#rrggbb", "#aarrggbb" or null for none',
);

/// `#rrggbb`, `#aarrggbb` or null, as a colour or none.
Color? parseColor(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const CommandError('`color` is "#rrggbb", "#aarrggbb" or null');
  }
  final String hex = value.startsWith('#') ? value.substring(1) : value;
  final int? parsed = int.tryParse(hex, radix: 16);
  if (parsed == null || (hex.length != 6 && hex.length != 8)) {
    throw CommandError('`color` "$value" is not #rrggbb or #aarrggbb');
  }
  return Color(hex.length == 6 ? 0xFF000000 | parsed : parsed);
}

List<CommandSpec> objectCommands(EditorContext context) {
  final EditorModel model = context.model;
  final bool mac = platformEditingConvention == EditingConvention.mac;

  /// [ok] once a document and a selection exist, with [reason] otherwise.
  String? Function(CommandArgs) selectionThat(
    bool Function() ok,
    String reason,
  ) =>
      (CommandArgs args) =>
          context.needsSelection(args) ?? (ok() ? null : reason);

  return <CommandSpec>[
    // --- structure ------------------------------------------------------------
    CommandSpec(
      id: 'object.group',
      label: 'Group',
      shortcut: const KeyGesture(logicalKeyG, command: true),
      when: context.needsSelected(2),
      run: (_) => model.group(),
    ),
    CommandSpec(
      id: 'object.ungroup',
      label: 'Ungroup',
      shortcut: const KeyGesture(logicalKeyU, command: true),
      when: selectionThat(() => model.singleSelection is VectorGroup,
          'select exactly one group to ungroup'),
      run: (_) => model.ungroup(),
    ),
    CommandSpec(
      id: 'object.toCurves',
      label: 'Convert to curves',
      description: 'Replaces shapes and texts by curves with the same outline.',
      // CorelDRAW's Ctrl+Q; on a Mac that chord is Quit.
      shortcut: mac ? null : const KeyGesture(logicalKeyQ, command: true),
      when: selectionThat(
          () => model.canConvertToCurves, 'select a shape or a text'),
      run: (_) => model.convertSelectionToCurves(),
    ),
    CommandSpec(
      id: 'object.combine',
      label: 'Combine',
      description:
          'Joins the selected objects into one curve; overlaps become holes.',
      shortcut: const KeyGesture(logicalKeyL, command: true),
      when: selectionThat(() => model.canCombine, 'select two or more objects'),
      run: (_) => model.combineSelection(),
    ),
    CommandSpec(
      id: 'object.breakApart',
      label: 'Break Curve Apart',
      description:
          'Splits a curve of several outlines into one curve per outline.',
      shortcut: const KeyGesture(logicalKeyK, command: true),
      when: selectionThat(
          () => model.canBreakApart, 'select a curve with several outlines'),
      run: (_) => model.breakApartSelection(),
    ),

    // --- transformation -------------------------------------------------------
    CommandSpec(
      id: 'object.rotate',
      label: 'Rotate',
      params: const <CommandParam>[
        CommandParam('degrees', CommandParamType.number,
            required: true,
            description: 'clockwise; negative turns the other way'),
      ],
      when: context.needsSelection,
      run: (CommandArgs args) => model.rotateSelection(args.number('degrees')),
    ),
    CommandSpec(
      id: 'object.flip',
      label: 'Flip',
      params: const <CommandParam>[
        CommandParam('direction', CommandParamType.string,
            required: true, description: 'horizontal or vertical'),
      ],
      when: context.needsSelection,
      run: (CommandArgs args) => model.flipSelection(
        horizontal: oneOf(args, 'direction', const <String>[
              'horizontal',
              'vertical',
            ]) ==
            'horizontal',
      ),
    ),
    CommandSpec(
      id: 'object.move',
      label: 'Move',
      description: 'Moves the selection by dx, dy document units.',
      params: const <CommandParam>[
        CommandParam('dx', CommandParamType.number),
        CommandParam('dy', CommandParamType.number),
      ],
      when: context.needsSelection,
      run: (CommandArgs args) =>
          model.moveSelectionBy(args.number('dx', 0), args.number('dy', 0)),
    ),
    CommandSpec(
      id: 'object.nudge',
      label: 'Nudge',
      description: 'The arrow keys: one nudge, ten (big) or a tenth (small).',
      params: const <CommandParam>[
        CommandParam('dx', CommandParamType.integer),
        CommandParam('dy', CommandParamType.integer),
        CommandParam('step', CommandParamType.string,
            description: 'normal, big or small'),
      ],
      when: context.needsSelection,
      run: (CommandArgs args) {
        final String step = args.has('step')
            ? oneOf(args, 'step', const <String>['normal', 'big', 'small'])
            : 'normal';
        model.nudge(
          args.integer('dx', 0),
          args.integer('dy', 0),
          big: step == 'big',
          small: step == 'small',
        );
        return null;
      },
    ),
    CommandSpec(
      id: 'object.resize',
      label: 'Resize',
      params: const <CommandParam>[
        CommandParam('width', CommandParamType.number),
        CommandParam('height', CommandParamType.number),
      ],
      when: context.needsSelection,
      run: (CommandArgs args) => model.resizeSelectionTo(
        width: args.has('width') ? args.number('width') : null,
        height: args.has('height') ? args.number('height') : null,
      ),
    ),

    // --- paint ----------------------------------------------------------------
    CommandSpec(
      id: 'object.fill',
      label: 'Fill colour',
      description: "The selection's fill, or the next shapes' when nothing "
          'is selected.',
      params: const <CommandParam>[_color],
      when: context.needsDocument,
      run: (CommandArgs args) => model.setFill(parseColor(args['color'])),
    ),
    CommandSpec(
      id: 'object.outline',
      label: 'Outline colour',
      params: const <CommandParam>[_color],
      when: context.needsDocument,
      run: (CommandArgs args) => model.setStroke(parseColor(args['color'])),
    ),
  ];
}
