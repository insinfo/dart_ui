/// A searchable command dialog backed by the same registry as menus and keys.
library;

import '../commands/command_registry.dart';
import '../layout/edge_insets.dart';
import '../layout/render_flex.dart';
import 'basic.dart';
import 'controls.dart';
import 'dialogs.dart';
import 'focus.dart';
import 'widget.dart';

Future<void> showCommandPalette({
  required BuildContext context,
  required CommandRegistry registry,
  String title = 'Commands',
  String searchLabel = 'Search commands',
}) =>
    showDialog<void>(
        context: context,
        builder: (_) => CommandPalette(
            registry: registry, title: title, searchLabel: searchLabel));

/// Commands requiring explicit arguments stay in their parameterized UI.
/// Disabled commands remain visible with their reason.
class CommandPalette extends StatefulWidget {
  const CommandPalette(
      {super.key,
      required this.registry,
      this.title = 'Commands',
      this.searchLabel = 'Search commands'});
  final CommandRegistry registry;
  final String title;
  final String searchLabel;
  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final search = TextEditingController();
  final focus = FocusNode(debugLabel: 'Command palette');
  String query = '';

  @override
  void initState() {
    super.initState();
    focus.requestFocus();
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registry = widget.registry;
    final commands = registry.describe().where((c) {
      final params = c['params'];
      if (params is List &&
          params.any((p) => p is Map && p['required'] == true)) {
        return false;
      }
      return '${c['label']} ${c['id']}'
          .toLowerCase()
          .contains(query.toLowerCase());
    }).toList();
    void run(Map<String, Object?> command) {
      final id = command['id'] as String;
      closeDialog<void>(context);
      registry.execute(id);
    }

    return SizedBox(
        width: 520,
        child: Dialog(
          title: widget.title,
          onDismiss: () => closeDialog<void>(context),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                    controller: search,
                    autofocus: true,
                    focusNode: focus,
                    label: widget.searchLabel,
                    onChanged: (value) => setState(() => query = value),
                    onSubmitted: (_) {
                      final enabled = commands
                          .where((c) => c['enabled'] == true)
                          .firstOrNull;
                      if (enabled != null) run(enabled);
                    }),
                const SizedBox(height: 10),
                SizedBox(
                    height: 260,
                    child: ScrollViewer(
                        child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final c in commands)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Button(
                                  label:
                                      '${c['label']}${c['shortcut'] == null ? '' : '    ${c['shortcut']}'}${c['enabled'] == true ? '' : ' (${c['disabledReason'] ?? ''})'}',
                                  accent: false,
                                  onPressed: c['enabled'] == true
                                      ? () => run(c)
                                      : null)),
                      ],
                    ))),
              ]),
        ));
  }
}
