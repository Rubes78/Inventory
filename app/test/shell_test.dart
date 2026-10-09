import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_pull/shell.dart';
import 'package:scan_pull/tpm_api.dart';

BrijjSession fakeSession() {
  String b64(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final token = '${b64({'alg': 'none'})}.${b64({'sub': '1', 'custom:userid': '1', 'custom:companyid': '99', 'custom:fullname': 'Test User', 'exp': 4102444800})}.sig';
  return BrijjSession(accessToken: token, refreshToken: 'r', sessionId: 's', companyName: 'Whiskered Thrifter', env: BrijjEnv.staging);
}

void main() {
  testWidgets('the drawer is the IMS mobile menu plus Scan Pull and History', (tester) async {
    await tester.pumpWidget(MaterialApp(home: AppShell(session: fakeSession(), onSignedOut: () async {})));
    await tester.pump();
    expect(find.text('Dashboard'), findsWidgets);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Test User'), findsOneWidget);
    expect(find.textContaining('Warehouse:', findRichText: true), findsOneWidget);
    for (final label in ['Work', 'Quick Relocation', 'Quick Transfer', 'Quick Receive', 'License Plates', 'Scan Pull', 'History', 'Logout']) {
      final inDrawer = find.descendant(of: find.byType(Drawer), matching: find.text(label));
      await tester.scrollUntilVisible(
        inDrawer,
        60,
        scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first,
      );
      expect(inDrawer, findsOneWidget, reason: label);
    }
  });
}
