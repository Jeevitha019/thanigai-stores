import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:malligai_kadai/main.dart';

void main() {
  test('serializes Thanigai Stores instances for the same Windows account', () {
    if (!Platform.isWindows) return;

    final first = WindowsAppInstanceLock.tryAcquire();
    expect(first, isNotNull);
    expect(WindowsAppInstanceLock.tryAcquire(), isNull);

    first!.release();
    final afterRelease = WindowsAppInstanceLock.tryAcquire();
    expect(afterRelease, isNotNull);
    afterRelease!.release();
  });
}
