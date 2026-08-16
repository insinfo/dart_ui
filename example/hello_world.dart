/// A minimal "Hello World" application in dart_ui.
///
/// Demonstrates the shortest complete application using the framework's widget
/// tree (`runApp`, `StatefulWidget`, `Column`, `Text`, `Button`, `Center`)
/// running on a native GPU window (or headless in CI).
///
/// Run on desktop:
/// ```
/// dart run example/hello_world.dart
/// ```
library;

import 'package:dart_ui/dart_ui.dart';

void main() => runApp(const HelloWorldApp());

/// The root widget displaying a simple Hello World counter interface.
final class HelloWorldApp extends StatefulWidget {
  const HelloWorldApp({super.key});

  @override
  State<HelloWorldApp> createState() => _HelloWorldAppState();
}

final class _HelloWorldAppState extends State<HelloWorldApp> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: 0xFFF4F6F8,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text(
              'Hello, World!',
              fontSize: 28,
            ),
            const SizedBox(height: 12),
            Text(
              'Cliques no botão: $_counter',
              fontSize: 16,
            ),
            const SizedBox(height: 20),
            Button(
              label: 'Incrementar',
              onPressed: () {
                setState(() {
                  _counter++;
                });
              },
            ),
          ],
        ),
      ),
    );
  }
}
