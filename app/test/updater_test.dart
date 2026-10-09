import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_pull/updater.dart';

void main() {
  test('parses version.json', () {
    final info = UpdateInfo.fromJson(
        {'version': '1.16.0', 'build': 19, 'apk': 'ScanPull-1.16.0.apk', 'size': 123, 'notes': 'Self-update'});
    expect(info.build, 19);
    expect(info.apk, 'ScanPull-1.16.0.apk');
    expect(info.size, 123);
  });

  testWidgets('update card shows only when an update is available', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UpdateCard())));
    expect(find.text('Install update'), findsNothing);

    Updater.available.value = UpdateInfo(version: '9.9.9', build: 999, apk: 'x.apk', notes: 'New stuff');
    await tester.pump();
    expect(find.text('Update available — v9.9.9'), findsOneWidget);
    expect(find.text('New stuff'), findsOneWidget);
    expect(find.text('Install update'), findsOneWidget);
    Updater.available.value = null;
  });
}
