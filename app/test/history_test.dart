import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_pull/history.dart';
import 'package:scan_pull/tpm_api.dart';

BrijjSession fakeSession() {
  String b64(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final token = '${b64({'alg': 'none'})}.${b64({'sub': '1', 'custom:userid': '1', 'custom:companyid': '99', 'custom:fullname': 'Test User', 'exp': 4102444800})}.sig';
  return BrijjSession(accessToken: token, refreshToken: 'r', sessionId: 's', companyName: 'Whiskered Thrifter', env: BrijjEnv.staging);
}

void main() {
  testWidgets('history without a Scan Pull location explains TPM mode and has a device tab', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HistoryPage(session: fakeSession())));
    await tester.pump();
    expect(find.text('Movement orders'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('No IMS Scan Pull location'), findsOneWidget);
  });

  test('activity entry counts and movement order refs', () {
    final e = ActivityEntry(
      at: DateTime(2026, 10, 9),
      user: 'Test User',
      company: 'Whiskered Thrifter',
      env: 'Staging',
      destination: 'Memphis / Scan Pull - Memphis',
      reason: 'Scan Pull: Damaged',
      items: [
        ActivityItem(barcode: '1', note: 'MO-99-261009-0001', price: 1.99),
        ActivityItem(barcode: '2', note: 'MO-99-261009-0001', price: 5),
        ActivityItem(barcode: '3', error: 'Skipped — Not in IMS inventory'),
        ActivityItem(barcode: '4', error: 'Movement failed (MO-99-261009-0002)'),
      ],
    );
    final r = ActivityEntry.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
    expect([r.pulled, r.skipped, r.failed], [2, 1, 1]);
    expect(r.value, closeTo(6.99, 0.001));
    expect(r.refs, ['MO-99-261009-0001']);
  });

  test('movement order summary parses an IMS list item', () {
    final o = MovementOrderSummary.fromJson({
      'id': 415,
      'referenceNumber': 'MO-99-261009-0001',
      'status': 5,
      'relocationType': 3,
      'reason': 'Scan Pull: Color-week pull (Red)',
      'specialInstruction': 'Brijj Inventory app v1.21.0',
      'totalProductCount': 3,
      'totalPrice': 0,
      'createdAt': '2026-10-09T14:28:45.72566+00:00',
      'completedBy': 'Whiskered Producer',
      'user': {'id': 4210, 'name': 'Whiskered Producer'},
      'warehouse': {'id': 262, 'name': 'Memphis'},
    });
    expect(o.isScanPull, isTrue);
    expect(o.createdById, '4210');
    expect(o.relocationLabel, 'Product');
    expect(MoveStatus.label(o.status), 'Completed');
  });
}
