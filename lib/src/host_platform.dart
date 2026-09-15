import 'dart:io';

bool get isWindows11Host => isWindows11Version(
  isWindows: Platform.isWindows,
  version: Platform.operatingSystemVersion,
);

bool isWindows11Version({required bool isWindows, required String version}) {
  if (!isWindows || version.toLowerCase().contains('windows server')) {
    return false;
  }
  // Dart reads CurrentBuild from the registry and formats it as (Build N).
  // ProductName can still say Windows 10 on Windows 11. The first Windows 11
  // release is build 22000; use the build rather than that display name.
  final match = RegExp(
    r'\(Build (\d+)\)',
    caseSensitive: false,
  ).firstMatch(version);
  if (match != null) return int.parse(match.group(1)!) >= 22000;
  return RegExp(r'Windows\s+11\b', caseSensitive: false).hasMatch(version);
}
