/// Layers: new, activate, show and hide, lock, reorder, rename, delete.
///
/// Every layer command takes the layer by `index` (bottom first), the
/// active one by default, and its checked and enabled state follows that
/// index - so a right-click menu on layer 2 shows layer 2's state.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import 'command_context.dart';

const CommandParam _index = CommandParam(
  'index',
  CommandParamType.integer,
  description: 'the layer, bottom first; the active one by default',
);

List<CommandSpec> layerCommands(EditorContext context) {
  final EditorModel model = context.model;

  /// The layer [args] name, or why there is none.
  (VectorLayer?, String?) layerOf(CommandArgs args) {
    final String? document = context.needsDocument(args);
    if (document != null) return (null, document);
    final List<VectorLayer> layers = model.active.layers;
    if (!args.has('index')) return (model.active.layer, null);
    final Object? raw = args['index'];
    final int? index = raw is int ? raw : (raw is double ? raw.toInt() : null);
    if (index == null || index < 0 || index >= layers.length) {
      return (null, 'no such layer: the page has ${layers.length}');
    }
    return (layers[index], null);
  }

  /// A command on one layer; [why] refuses it for that layer.
  CommandSpec onLayer({
    required String id,
    required String label,
    required Object? Function(VectorLayer layer, CommandArgs args) run,
    String? Function(VectorLayer layer)? why,
    bool Function(VectorLayer layer)? checked,
    List<CommandParam> extra = const <CommandParam>[],
  }) =>
      CommandSpec(
        id: id,
        label: label,
        params: <CommandParam>[_index, ...extra],
        when: (CommandArgs args) {
          final (VectorLayer? layer, String? reason) = layerOf(args);
          return reason ?? why?.call(layer!);
        },
        checked: checked == null
            ? null
            : (CommandArgs args) {
                final VectorLayer? layer = layerOf(args).$1;
                return layer != null && checked(layer);
              },
        run: (CommandArgs args) => run(layerOf(args).$1!, args),
      );

  int indexOf(VectorLayer layer) => model.active.layers.indexOf(layer);

  return <CommandSpec>[
    CommandSpec(
      id: 'layer.new',
      label: 'New layer',
      when: context.needsDocument,
      run: (_) {
        model.addLayer();
        return <String, Object?>{'index': indexOf(model.active.layer)};
      },
    ),
    onLayer(
      id: 'layer.activate',
      label: 'Make active layer',
      checked: (VectorLayer layer) => identical(layer, model.active.layer),
      run: (VectorLayer layer, _) => model.activateLayer(layer),
    ),
    onLayer(
      id: 'layer.visible',
      label: 'Visible',
      checked: (VectorLayer layer) => layer.isVisible,
      extra: const <CommandParam>[
        CommandParam('visible', CommandParamType.boolean,
            description: 'toggles when left out'),
      ],
      run: (VectorLayer layer, CommandArgs args) {
        model.setLayerVisible(layer, args.flag('visible', !layer.isVisible));
        return layer.isVisible;
      },
    ),
    onLayer(
      id: 'layer.lock',
      label: 'Locked',
      checked: (VectorLayer layer) => !layer.isEditable,
      extra: const <CommandParam>[
        CommandParam('locked', CommandParamType.boolean,
            description: 'toggles when left out'),
      ],
      run: (VectorLayer layer, CommandArgs args) {
        model.setLayerLocked(layer, args.flag('locked', layer.isEditable));
        return !layer.isEditable;
      },
    ),
    onLayer(
      id: 'layer.raise',
      label: 'Raise layer',
      why: (VectorLayer layer) =>
          indexOf(layer) < model.active.layers.length - 1
              ? null
              : 'already the top layer',
      run: (VectorLayer layer, _) => model.moveLayer(layer, up: true),
    ),
    onLayer(
      id: 'layer.lower',
      label: 'Lower layer',
      why: (VectorLayer layer) =>
          indexOf(layer) > 0 ? null : 'already the bottom layer',
      run: (VectorLayer layer, _) => model.moveLayer(layer, up: false),
    ),
    onLayer(
      id: 'layer.rename',
      label: 'Rename layer',
      extra: const <CommandParam>[
        CommandParam('name', CommandParamType.string, required: true),
      ],
      run: (VectorLayer layer, CommandArgs args) =>
          model.renameLayer(layer, args.string('name')),
    ),
    onLayer(
      id: 'layer.delete',
      label: 'Delete layer',
      why: (_) => model.active.layers.length > 1
          ? null
          : 'the last layer cannot be deleted',
      run: (VectorLayer layer, _) => model.deleteLayer(layer),
    ),
  ];
}
