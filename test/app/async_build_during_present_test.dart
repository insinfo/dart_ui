import 'package:test/test.dart';

import 'support/pending_present_probe.dart';

void main() {
  test('a build queued during presentation requests the next frame',
      verifyBuildDuringPresentation);
}
