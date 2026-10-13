/// Shapes created by parameters - what the drawing tools make with the
/// pointer, for a script, a test or an automation client.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import 'command_context.dart';

const List<CommandParam> _box = <CommandParam>[
  CommandParam('x', CommandParamType.number, required: true),
  CommandParam('y', CommandParamType.number, required: true),
  CommandParam('width', CommandParamType.number, required: true),
  CommandParam('height', CommandParamType.number, required: true),
];

void _positive(CommandArgs args) {
  if (args.number('width') <= 0 || args.number('height') <= 0) {
    throw const CommandError('`width` and `height` must be above zero');
  }
}

List<CommandSpec> shapeCommands(EditorContext context) {
  final EditorModel model = context.model;

  /// Adds [object] to the active layer as one undo step, wearing the
  /// current fill and outline, and selects it.
  Map<String, Object?> create(SelectableObject object) {
    final DocumentSession session = model.active;
    final VectorLayer layer = session.layer;
    if (!layer.isEditable || !layer.isVisible) {
      throw CommandError('${layer.name} is locked or hidden');
    }
    session.api.methods.addObject(layer, object);
    model.objectCreated(object);
    session.selection.select(object);
    return <String, Object?>{'index': context.layerObjects.indexOf(object)};
  }

  DocumentMethods methods() => model.active.api.methods;

  return <CommandSpec>[
    CommandSpec(
      id: 'shape.curve',
      label: 'Curve',
      description: 'Straight segments through points given as '
          '[x1, y1, x2, y2, ...]; closed joins the last to the first.',
      params: const <CommandParam>[
        CommandParam('points', CommandParamType.list, required: true),
        CommandParam('closed', CommandParamType.boolean),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) {
        final List<Object?> raw = args.list('points');
        if (raw.length < 4 ||
            raw.length.isOdd ||
            raw.any((Object? v) => v is! num || !v.isFinite)) {
          throw const CommandError(
              '`points` is an even list of at least four numbers');
        }
        final List<double> n = <double>[
          for (final Object? v in raw) (v! as num).toDouble(),
        ];
        return create(methods().createCurve(paths: <VectorPath>[
          VectorPath(
            start: Offset(n[0], n[1]),
            points: <Object>[
              for (var i = 2; i < n.length; i += 2) Offset(n[i], n[i + 1]),
            ],
            closure: args.has('closed') && args['closed'] == true
                ? PathClosure.closed
                : PathClosure.opened,
          ),
        ]));
      },
    ),
    CommandSpec(
      id: 'shape.rectangle',
      label: 'Rectangle',
      description: 'A rectangle at x, y (top-left), in document units.',
      params: _box,
      when: context.needsDocument,
      run: (CommandArgs args) {
        _positive(args);
        return create(methods().createRectangle(
          x: args.number('x'),
          y: args.number('y'),
          width: args.number('width'),
          height: args.number('height'),
        ));
      },
    ),
    CommandSpec(
      id: 'shape.ellipse',
      label: 'Ellipse',
      description: 'The ellipse inside the box at x, y.',
      params: _box,
      when: context.needsDocument,
      run: (CommandArgs args) {
        _positive(args);
        final double rx = args.number('width') / 2;
        final double ry = args.number('height') / 2;
        return create(methods().createCircle(
          cx: args.number('x') + rx,
          cy: args.number('y') + ry,
          rx: rx,
          ry: ry,
        ));
      },
    ),
    CommandSpec(
      id: 'shape.polygon',
      label: 'Polygon',
      description: 'A regular polygon centred at cx, cy.',
      params: const <CommandParam>[
        CommandParam('cx', CommandParamType.number, required: true),
        CommandParam('cy', CommandParamType.number, required: true),
        CommandParam('radius', CommandParamType.number, required: true),
        CommandParam('corners', CommandParamType.integer),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) {
        final int corners = args.integer('corners', model.polygonCorners);
        if (corners < 3 || corners > 1000) {
          throw const CommandError('`corners` is from 3 to 1000');
        }
        return create(methods().createPolygon(
          cx: args.number('cx'),
          cy: args.number('cy'),
          radius: args.number('radius'),
          cornersNum: corners,
        ));
      },
    ),
    CommandSpec(
      id: 'shape.text',
      label: 'Text',
      description: 'Artistic text with its baseline starting at x, y.',
      params: const <CommandParam>[
        CommandParam('x', CommandParamType.number, required: true),
        CommandParam('y', CommandParamType.number, required: true),
        CommandParam('text', CommandParamType.string, required: true),
        CommandParam('size', CommandParamType.number,
            description: 'points; 18 by default'),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) {
        final VectorText text = methods().createText(
          text: args.string('text'),
          x: args.number('x'),
          y: args.number('y'),
        );
        text.style = text.style.copyWith(
          textStyle:
              text.style.textStyle.copyWith(fontSize: args.number('size', 18)),
        );
        text.update();
        return create(text);
      },
    ),
  ];
}
