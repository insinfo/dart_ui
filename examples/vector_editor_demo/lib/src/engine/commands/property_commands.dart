/// Properties: every value CorelDRAW's Object Properties docker (Alt+Enter)
/// edits, as a command - so the docker, the property bar, a script and an
/// automation client set an outline width the same way, and each change is
/// one undo step.
///
/// Lengths are in points, the document's own unit; a window converts what
/// it shows.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import 'command_context.dart';

List<CommandSpec> propertyCommands(EditorContext context) {
  final EditorModel model = context.model;

  /// The selected objects of type [T].
  List<T> selected<T extends SelectableObject>() =>
      model.selection.selectedObjects.whereType<T>().toList();

  /// Runs once a document and a selection with a [T] in it exist.
  String? Function(CommandArgs) needs<T extends SelectableObject>(
          String what) =>
      context.selectionThat(() => selected<T>().isNotEmpty, 'select $what');

  /// Changes every selected [T] in one undo step named [label].
  Object? each<T extends SelectableObject>(
      String label, void Function(T object) change,
      {Object? coalesce}) {
    final List<T> objects = selected<T>();
    model.edit(label, () {
      for (final T object in objects) {
        change(object);
        object.update();
      }
    }, coalesce: coalesce);
    return <String, Object?>{'changed': objects.length};
  }

  /// Whether every selected object's style says [value] for [read].
  bool allSay(Object? value, Object? Function(VectorStyle style) read) {
    final List<SelectableObject> objects = model.selection.selectedObjects;
    return value != null &&
        objects.isNotEmpty &&
        objects.every((SelectableObject o) => read(o.style) == value);
  }

  return <CommandSpec>[
    // --- geometry -------------------------------------------------------------
    CommandSpec(
      id: 'object.position',
      label: 'Position',
      description: 'Puts the selection\'s top-left corner at x, y (points); '
          'either may be left out.',
      params: const <CommandParam>[
        CommandParam('x', CommandParamType.number),
        CommandParam('y', CommandParamType.number),
      ],
      when: context.needsSelection,
      run: (CommandArgs args) {
        final Rect bounds = model.selection.selectionBounds;
        model.moveSelectionBy(
          args.has('x') ? args.number('x') - bounds.left : 0,
          args.has('y') ? args.number('y') - bounds.top : 0,
        );
        return null;
      },
    ),

    // --- outline --------------------------------------------------------------
    CommandSpec(
      id: 'object.outlineWidth',
      label: 'Outline width',
      description: 'The selection\'s outline width in points; 0 is none.',
      params: const <CommandParam>[
        CommandParam('width', CommandParamType.number, required: true),
      ],
      when: context.needsSelection,
      run: (CommandArgs args) {
        final double width = args.number('width');
        if (width < 0) throw const CommandError('`width` cannot be negative');
        model.applyToSelection((VectorStyle style) =>
            style.copyWith(stroke: style.stroke.copyWith(width: width)));
        return null;
      },
    ),
    CommandSpec(
      id: 'object.outlineStyle',
      label: 'Outline style',
      description: 'Line caps (butt, round, square), joins (miter, round, '
          'bevel) and dashes (a list of lengths in points; empty is solid).',
      params: const <CommandParam>[
        CommandParam('cap', CommandParamType.string),
        CommandParam('join', CommandParamType.string),
        CommandParam('dash', CommandParamType.list),
      ],
      when: context.needsSelection,
      checked: (CommandArgs args) => args.has('cap')
          ? allSay(args['cap'], (VectorStyle s) => s.stroke.cap.name)
          : args.has('join')
              ? allSay(args['join'], (VectorStyle s) => s.stroke.join.name)
              : args.has('dash') &&
                  allSay(
                      args
                          .list('dash')
                          .map((Object? e) => (e! as num).toDouble())
                          .join(','),
                      (VectorStyle s) => s.stroke.dashPattern.join(',')),
      run: (CommandArgs args) {
        final LineCap? cap = args.has('cap')
            ? LineCap.values.byName(oneOf(
                args, 'cap', <String>[for (final c in LineCap.values) c.name]))
            : null;
        final LineJoin? join = args.has('join')
            ? LineJoin.values.byName(oneOf(args, 'join',
                <String>[for (final j in LineJoin.values) j.name]))
            : null;
        List<double>? dash;
        if (args.has('dash')) {
          dash = <double>[];
          for (final Object? length in args.list('dash')) {
            if (length is! num || length < 0 || !length.isFinite) {
              throw const CommandError(
                  '`dash` is a list of non-negative lengths');
            }
            dash.add(length.toDouble());
          }
        }
        model.applyToSelection((VectorStyle style) => style.copyWith(
            stroke: style.stroke
                .copyWith(cap: cap, join: join, dashPattern: dash)));
        return null;
      },
    ),

    CommandSpec(
      id: 'object.arrows',
      label: 'Arrowheads',
      description: 'The heads on the open ends of an outline: none, '
          'triangle, open, stealth, circle, square, diamond or bar.',
      params: const <CommandParam>[
        CommandParam('start', CommandParamType.string),
        CommandParam('end', CommandParamType.string),
      ],
      when: context.needsSelection,
      checked: (CommandArgs args) => args.has('start')
          ? allSay(args['start'],
              (VectorStyle s) => ArrowHead.of(s.stroke.startArrow).name)
          : args.has('end') &&
              allSay(args['end'],
                  (VectorStyle s) => ArrowHead.of(s.stroke.endArrow).name),
      run: (CommandArgs args) {
        final List<String> names = <String>[
          for (final ArrowHead head in ArrowHead.values) head.name,
        ];
        // 0 is none: copyWith cannot clear a field with null.
        final int? start = args.has('start')
            ? ArrowHead.values.byName(oneOf(args, 'start', names)).index
            : null;
        final int? end = args.has('end')
            ? ArrowHead.values.byName(oneOf(args, 'end', names)).index
            : null;
        model.applyToSelection((VectorStyle style) => style.copyWith(
            stroke: style.stroke.copyWith(startArrow: start, endArrow: end)));
        return null;
      },
    ),

    // --- fill -----------------------------------------------------------------
    CommandSpec(
      id: 'object.fillRule',
      label: 'Fill rule',
      description: 'How overlapping outlines of one object fill: nonZero '
          'merges them, evenOdd makes holes.',
      params: const <CommandParam>[
        CommandParam('rule', CommandParamType.string, required: true),
      ],
      when: context.needsSelection,
      checked: (CommandArgs args) =>
          allSay(args['rule'], (VectorStyle s) => s.fill.fillRule.name),
      run: (CommandArgs args) {
        final FillRule rule = FillRule.values.byName(oneOf(
            args, 'rule', <String>[for (final r in FillRule.values) r.name]));
        model.applyToSelection((VectorStyle style) =>
            style.copyWith(fill: style.fill.copyWith(fillRule: rule)));
        return null;
      },
    ),

    // --- shapes ---------------------------------------------------------------
    CommandSpec(
      id: 'rectangle.round',
      label: 'Corner roundness',
      description: 'Rounds every corner of the selected rectangles, 0 to '
          '100 percent of the shorter side\'s half.',
      params: const <CommandParam>[
        CommandParam('percent', CommandParamType.number, required: true),
      ],
      when: needs<VectorRectangle>('a rectangle'),
      run: (CommandArgs args) {
        final double corner = (args.number('percent') / 100).clamp(0.0, 1.0);
        return each<VectorRectangle>(
            'Corner radius ${(corner * 100).round()}%',
            (VectorRectangle r) =>
                r.corners = <double>[corner, corner, corner, corner]);
      },
    ),
    CommandSpec(
      id: 'ellipse.type',
      label: 'Ellipse type',
      description: 'What the selected ellipses draw when they are not whole: '
          'arc, chord or pieslice.',
      params: const <CommandParam>[
        CommandParam('type', CommandParamType.string, required: true),
      ],
      when: needs<VectorCircle>('an ellipse'),
      checked: (CommandArgs args) {
        final List<VectorCircle> circles = selected<VectorCircle>();
        return args.has('type') &&
            circles.isNotEmpty &&
            circles.every((VectorCircle c) => c.arcType.name == args['type']);
      },
      run: (CommandArgs args) {
        final ArcType type = ArcType.values.byName(oneOf(
            args, 'type', <String>[for (final t in ArcType.values) t.name]));
        return each<VectorCircle>(
            'Ellipse: ${type.name}', (VectorCircle c) => c.arcType = type);
      },
    ),
    CommandSpec(
      id: 'polygon.corners',
      label: 'Polygon corners',
      params: const <CommandParam>[
        CommandParam('corners', CommandParamType.integer, required: true),
      ],
      when: needs<VectorPolygon>('a polygon'),
      run: (CommandArgs args) {
        final int corners = args.integer('corners');
        if (corners < 3 || corners > 1000) {
          throw const CommandError('`corners` is 3 to 1000');
        }
        return each<VectorPolygon>(
            '$corners corners', (VectorPolygon p) => p.cornersNum = corners);
      },
    ),

    // --- text -----------------------------------------------------------------
    CommandSpec(
      id: 'text.content',
      label: 'Text',
      description: 'Replaces what the selected texts say. Typing in a row '
          'coalesces into one undo step per object.',
      params: const <CommandParam>[
        CommandParam('text', CommandParamType.string, required: true),
      ],
      when: needs<VectorText>('a text'),
      run: (CommandArgs args) {
        final String text = args.string('text');
        final List<VectorText> texts = selected<VectorText>();
        return each<VectorText>('Edit text', (VectorText t) {
          t.textContent = text;
        }, coalesce: texts.length == 1 ? texts.single : null);
      },
    ),
    CommandSpec(
      id: 'text.size',
      label: 'Font size',
      description: 'The selected texts\' size in points.',
      params: const <CommandParam>[
        CommandParam('size', CommandParamType.number, required: true),
      ],
      when: needs<VectorText>('a text'),
      run: (CommandArgs args) {
        final double size = args.number('size');
        if (size < 1 || size > 4000) {
          throw const CommandError('`size` is 1 to 4000 points');
        }
        model.active.api.restyle(
            selected<VectorText>(),
            (VectorStyle style) => style.copyWith(
                textStyle: style.textStyle.copyWith(fontSize: size)));
        model.touch('Font size ${size.round()}');
        return null;
      },
    ),
    CommandSpec(
      id: 'text.font',
      label: 'Font',
      description: 'The selected texts\' typeface family, by name; one '
          'this machine lacks draws in the interface face.',
      params: const <CommandParam>[
        CommandParam('family', CommandParamType.string, required: true),
      ],
      when: needs<VectorText>('a text'),
      checked: (CommandArgs args) =>
          allSay(args['family'], (VectorStyle s) => s.textStyle.fontFamily),
      run: (CommandArgs args) {
        final String family = args.string('family').trim();
        if (family.isEmpty) throw const CommandError('`family` is empty');
        model.active.api.restyle(
            selected<VectorText>(),
            (VectorStyle style) => style.copyWith(
                textStyle: style.textStyle.copyWith(fontFamily: family)));
        model.touch('Font $family');
        return null;
      },
    ),
    for (final (
      String id,
      String label,
      bool Function(TextStyleDescriptor),
      TextStyleDescriptor Function(TextStyleDescriptor, bool)
    ) toggle in <(
      String,
      String,
      bool Function(TextStyleDescriptor),
      TextStyleDescriptor Function(TextStyleDescriptor, bool)
    )>[
      (
        'text.bold',
        'Bold',
        (TextStyleDescriptor t) => t.bold,
        (TextStyleDescriptor t, bool on) => t.copyWith(bold: on),
      ),
      (
        'text.italic',
        'Italic',
        (TextStyleDescriptor t) => t.italic,
        (TextStyleDescriptor t, bool on) => t.copyWith(italic: on),
      ),
    ])
      CommandSpec(
        id: toggle.$1,
        label: toggle.$2,
        description: 'Turns ${toggle.$2.toLowerCase()} on or off for the '
            'selected texts; `on` sets it, no argument toggles.',
        params: const <CommandParam>[
          CommandParam('on', CommandParamType.boolean),
        ],
        shortcut: toggle.$1 == 'text.bold'
            ? const KeyGesture(logicalKeyB, command: true)
            : const KeyGesture(logicalKeyI, command: true),
        when: needs<VectorText>('a text'),
        checked: (_) {
          final List<VectorText> texts = selected<VectorText>();
          return texts.isNotEmpty &&
              texts.every((VectorText t) => toggle.$3(t.style.textStyle));
        },
        run: (CommandArgs args) {
          final List<VectorText> texts = selected<VectorText>();
          final bool on = args.has('on')
              ? args['on'] == true
              : !texts.every((VectorText t) => toggle.$3(t.style.textStyle));
          model.active.api.restyle(
              texts,
              (VectorStyle style) =>
                  style.copyWith(textStyle: toggle.$4(style.textStyle, on)));
          model.touch('${toggle.$2} ${on ? 'on' : 'off'}');
          return on;
        },
      ),
    CommandSpec(
      id: 'text.align',
      label: 'Alignment',
      description: 'Where the selected texts grow from their anchor: left, '
          'center or right; justify spreads the lines of a paragraph text '
          'to both edges of its frame.',
      params: const <CommandParam>[
        CommandParam('align', CommandParamType.string, required: true),
      ],
      when: needs<VectorText>('a text'),
      checked: (CommandArgs args) =>
          allSay(args['align'], (VectorStyle s) => s.textStyle.alignment.name),
      run: (CommandArgs args) {
        final VectorTextAlign align = VectorTextAlign.values.byName(oneOf(args,
            'align', const <String>['left', 'center', 'right', 'justify']));
        model.active.api.restyle(
            selected<VectorText>(),
            (VectorStyle style) => style.copyWith(
                textStyle: style.textStyle.copyWith(alignment: align)));
        model.touch('Aligned ${align.name}');
        return null;
      },
    ),
  ];
}
