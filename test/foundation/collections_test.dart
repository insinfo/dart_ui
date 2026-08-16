import 'package:dart_ui/src/foundation/collections.dart';
import 'package:test/test.dart';

void main() {
  group('ListNullableAccessors', () {
    test('returns null for an empty list', () {
      expect(<int>[].lastOrNull, isNull);
    });

    test('returns the final element without changing the list', () {
      final List<int> values = <int>[1, 2, 3];

      expect(values.lastOrNull, 3);
      expect(values, <int>[1, 2, 3]);
    });

    test('preserves a nullable final element', () {
      expect(<int?>[1, null].lastOrNull, isNull);
    });
  });
}
