import 'package:dart_ui/dart_ui.dart';
import 'package:web/web.dart' as web;

import 'signer_app.dart';
import 'signer_client.dart';
import 'web_fonts.dart';

Future<void> main() async {
  await installBrowserFonts();
  runApp(
    const BrowserSignerApp(client: PageSignerClient()),
    options: ApplicationOptions(
      title: 'Dart UI Assinador ICP-Brasil',
      size: const Size(1180, 760),
      minimumSize: const Size(800, 560),
      clearColor: const Color(0xFFF3F7FC),
      onError: (error) => web.document.documentElement?.setAttribute(
        'data-dart-ui-error',
        '${error.phase.name}: ${error.cause}',
      ),
    ),
  );
}
