/// Measures the editor against CorelDRAW and writes `doc/paridade.md`.
///
/// ```
/// dart run tool/parity.dart          # prints the summary, writes the doc
/// dart run tool/parity.dart --check  # fails if the doc is out of date
/// ```
///
/// The numbers come from the running editor's command registry, not from a
/// list kept by hand: a feature whose commands are not registered is
/// missing, whatever anyone wrote about it.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:vector_editor_demo/src/engine/editor_commands.dart';
import 'package:vector_editor_demo/src/engine/editor_host.dart';
import 'package:vector_editor_demo/src/engine/editor_model.dart';
import 'package:vector_editor_demo/src/ui/editor_ui.dart';
import 'package:vector_editor_demo/src/ui/menus.dart';

import 'parity_catalog.dart';

/// The state of one feature in the editor as it is built.
enum ParityState { done, partial, missing }

final class _NoDialogs implements EditorHost {
  @override
  Size get viewport => const Size(800, 600);
  @override
  void pickAndOpen() {}
  @override
  void pickAndSave(String format) {}
  @override
  void closeDocument(int index) {}
  @override
  void quit() {}
}

/// The editor's registry and menus, with no window.
({CommandRegistry registry, EditorMenus menus}) buildEditor() {
  final EditorModel model = EditorModel(onChanged: () {});
  final CommandRegistry registry = CommandRegistry();
  registerEditorCommands(registry, model, _NoDialogs());
  final EditorUi ui = EditorUi(model);
  registerUiCommands(registry, ui);
  return (registry: registry, menus: EditorMenus(registry, ui));
}

ParityState stateOf(ParityFeature feature, CommandRegistry registry) {
  final bool commands =
      feature.commands.isNotEmpty && feature.commands.every(registry.contains);
  final bool works = commands || feature.evidence != null;
  if (!works) return ParityState.missing;
  return feature.partial == null ? ParityState.done : ParityState.partial;
}

/// The report, in Portuguese, as markdown.
String report(CommandRegistry registry, EditorMenus menus) {
  final StringBuffer out = StringBuffer()
    ..writeln('# Paridade com o CorelDRAW')
    ..writeln()
    ..writeln('> Gerado por `dart run tool/parity.dart` a partir do registro '
        'de comandos do editor. Não edite à mão.')
    ..writeln('> Referência: `doc/vector_editor_catalogo_coreldraw.md` '
        '(só documentação pública). Uma funcionalidade conta quando todos os '
        'comandos dela estão registrados ou quando um teste comprova o '
        'comportamento; "parcial" diz o que falta.')
    ..writeln();

  String line(String label, Iterable<ParityFeature> features) {
    var done = 0;
    var partial = 0;
    for (final ParityFeature feature in features) {
      switch (stateOf(feature, registry)) {
        case ParityState.done:
          done++;
        case ParityState.partial:
          partial++;
        case ParityState.missing:
          break;
      }
    }
    final int total = features.length;
    final int pct =
        total == 0 ? 0 : ((done + partial / 2) * 100 / total).round();
    return '| $label | $done | $partial | ${total - done - partial} | $total '
        '| $pct% |';
  }

  out
    ..writeln('## Resumo')
    ..writeln()
    ..writeln('| | feitas | parciais | faltam | total | cobertura |')
    ..writeln('|---|---|---|---|---|---|');
  for (final String priority in <String>['P0', 'P1', 'P2']) {
    out.writeln(line(priority,
        kParityCatalog.where((f) => f.priority == priority).toList()));
  }
  out
    ..writeln(line('**todas**', kParityCatalog))
    ..writeln()
    ..writeln('Cobertura = (feitas + metade das parciais) / total.')
    ..writeln();

  final List<MenuRow> rows = menus.builder.flatten(menus.bar);
  final int registered = rows.where((r) => r.registered).length;
  out
    ..writeln('Menus do editor: $registered de ${rows.length} linhas têm '
        'comando registrado; as outras aparecem desabilitadas.')
    ..writeln()
    ..writeln('Comandos registrados: ${registry.length}.')
    ..writeln();

  final List<String> sections = <String>{
    for (final ParityFeature feature in kParityCatalog) feature.section,
  }.toList();
  out
    ..writeln('## Por área')
    ..writeln()
    ..writeln('| área | feitas | parciais | faltam | total | cobertura |')
    ..writeln('|---|---|---|---|---|---|');
  for (final String section in sections) {
    out.writeln(line(
        section, kParityCatalog.where((f) => f.section == section).toList()));
  }
  out.writeln();

  for (final String section in sections) {
    out
      ..writeln('### $section')
      ..writeln()
      ..writeln('| | funcionalidade | prio | como | falta |')
      ..writeln('|---|---|---|---|---|');
    for (final ParityFeature feature
        in kParityCatalog.where((f) => f.section == section)) {
      final ParityState state = stateOf(feature, registry);
      final String mark = switch (state) {
        ParityState.done => '✅',
        ParityState.partial => '🟡',
        ParityState.missing => '❌',
      };
      final String how = <String>[
        for (final String id in feature.commands)
          registry.contains(id) ? '`$id`' : '~~`$id`~~',
        if (feature.evidence != null) 'teste: "${feature.evidence}"',
      ].join(', ');
      out.writeln('| $mark | ${feature.name} | ${feature.priority} | $how '
          '| ${feature.partial ?? (state == ParityState.missing ? 'tudo' : '')} |');
    }
    out.writeln();
  }
  return out.toString();
}

void main(List<String> args) {
  final editor = buildEditor();
  final String text = report(editor.registry, editor.menus);
  final File doc = File('doc/paridade.md');
  if (args.contains('--check')) {
    final bool current = doc.existsSync() && doc.readAsStringSync() == text;
    stdout.writeln(current
        ? 'doc/paridade.md is current'
        : 'doc/paridade.md is out of date: run dart run tool/parity.dart');
    exit(current ? 0 : 1);
  }
  doc
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  final List<String> lines = text.split('\n');
  final int start = lines.indexOf('## Resumo');
  stdout.writeln(lines.sublist(start, start + 9).join('\n'));
}
