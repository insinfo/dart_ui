/// Guides: added where a ruler is dragged to, removed, cleared.
///
/// A guide is named by its orientation and position - what the user sees -
/// rather than by an index into a layer they never look at.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import 'command_context.dart';

const List<CommandParam> _where = <CommandParam>[
  CommandParam('orientation', CommandParamType.string,
      required: true, description: 'horizontal or vertical'),
  CommandParam('position', CommandParamType.number,
      required: true, description: 'in points, across its orientation'),
];

List<CommandSpec> guideCommands(EditorContext context) {
  final EditorModel model = context.model;

  bool horizontal(CommandArgs args) =>
      oneOf(args, 'orientation', const <String>['horizontal', 'vertical']) ==
      'horizontal';

  return <CommandSpec>[
    CommandSpec(
      id: 'guide.add',
      label: 'Add guide',
      description: 'A guide line across the page - what dragging out of a '
          'ruler makes.',
      params: _where,
      when: context.needsDocument,
      run: (CommandArgs args) {
        final bool isHorizontal = horizontal(args);
        final double position = args.number('position');
        model.edit(
          isHorizontal ? 'Add horizontal guide' : 'Add vertical guide',
          () => model.guideLayer.children.add(VectorGuide(
            parent: model.guideLayer,
            position: position,
            isHorizontal: isHorizontal,
          )),
        );
        return model.guides.length - 1;
      },
    ),
    CommandSpec(
      id: 'guide.delete',
      label: 'Delete guide',
      params: _where,
      when: (CommandArgs args) {
        final String? document = context.needsDocument(args);
        if (document != null) return document;
        if (!args.has('orientation') || !args.has('position')) return null;
        return model.guideAt(horizontal(args), args.number('position')) == null
            ? 'no guide there'
            : null;
      },
      run: (CommandArgs args) {
        final VectorGuide guide =
            model.guideAt(horizontal(args), args.number('position'))!;
        model.edit(
            'Delete guide', () => model.guideLayer.children.remove(guide));
        return null;
      },
    ),
    CommandSpec(
      id: 'guide.move',
      label: 'Move guide',
      params: <CommandParam>[
        ..._where,
        const CommandParam('to', CommandParamType.number,
            required: true, description: 'the new position, in points'),
      ],
      when: (CommandArgs args) {
        final String? document = context.needsDocument(args);
        if (document != null) return document;
        if (!args.has('orientation') || !args.has('position')) return null;
        return model.guideAt(horizontal(args), args.number('position')) == null
            ? 'no guide there'
            : null;
      },
      run: (CommandArgs args) {
        final VectorGuide guide =
            model.guideAt(horizontal(args), args.number('position'))!;
        final double to = args.number('to');
        model.edit('Move guide', () => guide.position = to);
        return null;
      },
    ),
    CommandSpec(
      id: 'guide.clear',
      label: 'Clear guides',
      when: (CommandArgs args) =>
          context.needsDocument(args) ??
          (model.guides.isEmpty ? 'there are no guides' : null),
      run: (_) {
        model.edit('Clear guides', () => model.guideLayer.children.clear());
        return null;
      },
    ),
  ];
}
