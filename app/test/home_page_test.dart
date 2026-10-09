import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_pull/main.dart';
import 'package:scan_pull/tpm_api.dart';

BrijjSession fakeSession() {
  String b64(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final token = '${b64({'alg': 'none'})}.${b64({
    'sub': '1',
    'custom:userid': '1',
    'custom:companyid': '99',
    'custom:fullname': 'Test User',
    'exp': 4102444800,
  })}.sig';
  return BrijjSession(accessToken: token, refreshToken: 'r', sessionId: 's', companyName: 'Whiskered Thrifter');
}

void main() {
  testWidgets('home shows Scan Pull plus Transfers and Inventory Count placeholders', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HomePage(session: fakeSession(), onSignedOut: () async {})));
    await tester.pump();

    expect(find.text('Brijj Inventory'), findsOneWidget);
    expect(find.text('Test User · Whiskered Thrifter'), findsOneWidget);
    expect(find.text('Scan Pull'), findsOneWidget);
    expect(find.text('Transfers'), findsOneWidget);
    expect(find.text('Inventory Count'), findsOneWidget);
    expect(find.text('Coming soon'), findsNWidgets(2));

    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles.where((t) => t.enabled).length, 1, reason: 'only Scan Pull is enabled');
  });
}
