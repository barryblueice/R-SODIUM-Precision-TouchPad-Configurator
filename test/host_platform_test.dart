import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/host_platform.dart';

void main() {
  test(
    'Windows 11 is detected by build even when the product name says 10',
    () {
      for (final build in [22000, 22621, 26100, 28000]) {
        expect(
          isWindows11Version(
            isWindows: true,
            version: '"Windows 10 Pro for Workstations" 10.0 (Build $build)',
          ),
          isTrue,
        );
      }
    },
  );
  test('Windows 10, Server and non-Windows hosts remain unrestricted', () {
    expect(
      isWindows11Version(
        isWindows: true,
        version: '"Windows 10 Pro" 10.0 (Build 19045)',
      ),
      isFalse,
    );
    expect(
      isWindows11Version(
        isWindows: true,
        version: '"Windows Server 2025" 10.0 (Build 26100)',
      ),
      isFalse,
    );
    expect(
      isWindows11Version(isWindows: false, version: 'Linux (Build 28000)'),
      isFalse,
    );
  });
  test(
    'An explicit Windows 11 name is a fallback when no build is available',
    () {
      expect(
        isWindows11Version(isWindows: true, version: 'Windows 11 Pro'),
        isTrue,
      );
      expect(
        isWindows11Version(isWindows: true, version: 'Windows 10 Pro'),
        isFalse,
      );
    },
  );
}
