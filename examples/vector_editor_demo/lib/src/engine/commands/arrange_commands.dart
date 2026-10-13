/// Arrange: stacking order, and CorelDRAW's align and distribute keys.
library;

import 'package:dart_ui/commands.dart';

import '../editor_model.dart';
import 'command_context.dart';

/// CorelDRAW's one-letter align keys, used with the Pick tool.
///
/// C lines the centres up on a vertical axis and E on a horizontal one.
const List<(String, String, int, HorizontalAlign?, VerticalAlign?)> kAlignKeys =
    <(String, String, int, HorizontalAlign?, VerticalAlign?)>[
  ('object.alignLeft', 'Align left', logicalKeyL, HorizontalAlign.left, null),
  (
    'object.alignRight',
    'Align right',
    logicalKeyR,
    HorizontalAlign.right,
    null
  ),
  ('object.alignTop', 'Align top', logicalKeyT, null, VerticalAlign.top),
  (
    'object.alignBottom',
    'Align bottom',
    logicalKeyB,
    null,
    VerticalAlign.bottom
  ),
  (
    'object.alignCentersVertically',
    'Align centers vertically',
    logicalKeyC,
    HorizontalAlign.centre,
    null
  ),
  (
    'object.alignCentersHorizontally',
    'Align centers horizontally',
    logicalKeyE,
    null,
    VerticalAlign.middle
  ),
];

List<CommandSpec> arrangeCommands(EditorContext context) {
  final EditorModel model = context.model;

  CommandSpec order(
          String id, String label, KeyGesture key, bool up, bool toEnd) =>
      CommandSpec(
        id: id,
        label: label,
        shortcut: key,
        when: context.needsSelection,
        run: (_) => model.reorder(up: up, toEnd: toEnd),
      );

  return <CommandSpec>[
    order(
        'object.toFront',
        'To Front',
        const KeyGesture(logicalKeyPageUp, command: true, shift: true),
        true,
        true),
    order('object.forward', 'Forward One',
        const KeyGesture(logicalKeyPageUp, command: true), true, false),
    order('object.backward', 'Back One',
        const KeyGesture(logicalKeyPageDown, command: true), false, false),
    order(
        'object.toBack',
        'To Back',
        const KeyGesture(logicalKeyPageDown, command: true, shift: true),
        false,
        true),
    for (final (
          String id,
          String label,
          int key,
          HorizontalAlign? h,
          VerticalAlign? v
        ) in kAlignKeys)
      CommandSpec(
        id: id,
        label: label,
        description: 'With several objects, to the last one selected; with '
            'one, to the page.',
        shortcut: KeyGesture(key),
        when: context.needsSelection,
        run: (_) => model.alignTo(horizontal: h, vertical: v),
      ),
    CommandSpec(
      id: 'object.centerToPage',
      label: 'Center to page',
      shortcut: const KeyGesture(logicalKeyP),
      when: context.needsSelection,
      run: (_) => model.alignTo(
        horizontal: HorizontalAlign.centre,
        vertical: VerticalAlign.middle,
        toPage: true,
      ),
    ),
    CommandSpec(
      id: 'object.distribute',
      label: 'Distribute',
      description:
          'Spreads three or more objects evenly between the outermost two.',
      params: const <CommandParam>[
        CommandParam('direction', CommandParamType.string,
            required: true, description: 'horizontal or vertical'),
      ],
      when: context.needsSelected(3),
      run: (CommandArgs args) => model.applyDistribute(
        horizontal: oneOf(args, 'direction', const <String>[
              'horizontal',
              'vertical',
            ]) ==
            'horizontal',
      ),
    ),
    CommandSpec(
      id: 'object.align',
      label: 'Align',
      description: "Aligns the selection with the Align panel's settings.",
      when: context.needsSelection,
      run: (_) => model.applyAlign(),
    ),
  ];
}
