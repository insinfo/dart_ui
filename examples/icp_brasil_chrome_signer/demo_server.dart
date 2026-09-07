import 'dart:io';

Future<void> main() async {
  final root = Directory(
      '${File(Platform.script.toFilePath()).parent.path}${Platform.pathSeparator}demo');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8787);
  stdout.writeln('Demonstração: http://localhost:8787');
  await for (final request in server) {
    final path =
        request.uri.path == '/' ? 'index.html' : request.uri.path.substring(1);
    final file = File('${root.path}${Platform.pathSeparator}$path');
    if (!file.existsSync() ||
        !file.absolute.path.startsWith(root.absolute.path)) {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.headers.contentType = ContentType.parse(switch (
          file.path.split('.').last) {
        'css' => 'text/css',
        'js' => 'text/javascript',
        _ => 'text/html'
      });
      request.response.add(await file.readAsBytes());
    }
    await request.response.close();
  }
}
