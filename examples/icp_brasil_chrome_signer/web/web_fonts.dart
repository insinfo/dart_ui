import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:web/web.dart' as web;

Future<void> installBrowserFonts({String root = 'assets/fonts'}) async {
  Future<Uint8List> load(String name) async {
    final response = await web.window.fetch('$root/$name'.toJS).toDart;
    if (!response.ok) {
      throw StateError(
          'Não foi possível carregar $name: HTTP ${response.status}');
    }
    return (await response.arrayBuffer().toDart).toDart.asUint8List();
  }

  final fonts = await Future.wait(<Future<Uint8List>>[
    load(FrameworkFonts.uiFileName),
    load(FrameworkFonts.uiMediumFileName),
    load(FrameworkFonts.uiSemiBoldFileName),
    load(FrameworkFonts.iconFileName),
    load(FrameworkFonts.tablerIconFileName),
    load(FrameworkFonts.phosphorIconFileName),
  ]);
  final result = FrameworkFonts.installFromBytes(
    uiFont: fonts[0],
    uiMediumFont: fonts[1],
    uiSemiBoldFont: fonts[2],
    iconFont: fonts[3],
    tablerIconFont: fonts[4],
    phosphorIconFont: fonts[5],
    source: root,
  );
  if (!result.uiFontLoaded || !result.iconFontLoaded) {
    throw StateError('As fontes de interface do dart_ui não foram instaladas.');
  }
}
