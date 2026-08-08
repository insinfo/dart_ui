import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _Resource with DisposableMixin {
  _Resource(this.name, this.log);

  final String name;
  final List<String> log;

  @override
  void onDispose() => log.add(name);
}

void main() {
  group('DisposableMixin', () {
    test('runs the release exactly once however often dispose is called', () {
      final log = <String>[];
      final resource = _Resource('a', log)
        ..dispose()
        ..dispose()
        ..dispose();

      expect(log, <String>['a']);
      expect(resource.isDisposed, isTrue);
    });

    test('throwIfDisposed names the type so the log points somewhere', () {
      final resource = _Resource('a', <String>[])..dispose();

      expect(
        resource.throwIfDisposed,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('_Resource'),
        )),
      );
    });
  });

  group('DisposableBag', () {
    test('releases in reverse acquisition order', () {
      final log = <String>[];
      DisposableBag()
        ..add('port', () => log.add('port'))
        ..add('source', () => log.add('source'))
        ..add('window', () => log.add('window'))
        ..dispose();

      // The window depends on the source, which depends on the port, so the
      // window has to go first.
      expect(log, <String>['window', 'source', 'port']);
    });

    test('add returns the resource so acquisition and registration are one '
        'expression', () {
      final bag = DisposableBag();
      final resource = bag.add(_Resource('a', <String>[]), () {});

      expect(resource.name, 'a');
      expect(bag.length, 1);
    });

    test('a throwing release does not stop the others, and still surfaces',
        () {
      final log = <String>[];
      final bag = DisposableBag()
        ..add('first', () => log.add('first'))
        ..add('boom', () => throw StateError('release failed'))
        ..add('last', () => log.add('last'));

      expect(bag.dispose, throwsA(isA<StateError>()));
      // Everything was attempted despite the failure in the middle.
      expect(log, <String>['last', 'first']);
    });

    test('is idempotent and does not re-release', () {
      final log = <String>[];
      DisposableBag()
        ..add('a', () => log.add('a'))
        ..dispose()
        ..dispose();

      expect(log, <String>['a']);
    });

    test('refuses registration after disposal', () {
      final bag = DisposableBag()..dispose();

      expect(() => bag.add('late', () {}), throwsA(isA<StateError>()));
    });

    test('addDisposable wires a Disposable into the same ordering', () {
      final log = <String>[];
      DisposableBag()
        ..addDisposable(_Resource('inner', log))
        ..addDisposable(_Resource('outer', log))
        ..dispose();

      expect(log, <String>['outer', 'inner']);
    });
  });

  group('GenerationToken', () {
    test('accepts the current generation and nothing else', () {
      final token = GenerationToken();
      final stamped = token.current;

      expect(token.accepts(stamped), isTrue);

      token.invalidate();

      // The native side still holds `stamped`; this is the callback arriving
      // after shutdown that a null check could not have caught.
      expect(token.accepts(stamped), isFalse);
      expect(token.accepts(token.current), isTrue);
    });

    test('never reuses a generation, so a late callback cannot alias a new one',
        () {
      final token = GenerationToken();
      final seen = <int>{token.current};

      for (var i = 0; i < 100; i++) {
        expect(seen.add(token.invalidate()), isTrue);
      }
    });
  });
}
