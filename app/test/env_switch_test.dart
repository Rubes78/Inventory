import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_pull/main.dart';
import 'package:scan_pull/tpm_api.dart';

import 'home_page_test.dart' show fakeSession;

void main() {
  test('environments point at the right servers', () {
    expect(TpmApi(BrijjEnv.staging).companyApi, 'https://company-api.stg.rcscbs.com');
    expect(TpmApi(BrijjEnv.production).companyApi, 'https://company-api.brijjworks.com');
    expect(TpmApi(BrijjEnv.production).tpmApi, 'https://productionsystem-api.brijjworks.com');
    expect(TpmApi(BrijjEnv.production).imsApi, 'https://inventory-api.brijjworks.com');
  });

  test('session keeps its environment; old saved sessions are staging', () {
    final s = fakeSession();
    final prod = BrijjSession(
        accessToken: s.accessToken, refreshToken: 'r', sessionId: 's', companyName: 'C', env: BrijjEnv.production);
    expect(BrijjSession.fromJson(prod.toJson()).env, BrijjEnv.production);
    expect(BrijjSession.fromJson(prod.toJson()).companyLabel, 'C (production)');
    expect(BrijjSession.fromJson(prod.toJson()..remove('env')).env, BrijjEnv.staging);
  });

  testWidgets('sign-in page toggles between staging and production', (tester) async {
    activeEnv.value = BrijjEnv.staging;
    await tester.pumpWidget(MaterialApp(home: LoginPage(onSignedIn: (_) async {})));
    await tester.pump();

    expect(find.textContaining('Staging (stg.rcscbs.com)'), findsOneWidget);
    await tester.tap(find.text('Production'));
    await tester.pump();
    expect(find.textContaining('Production (brijjworks.com)'), findsOneWidget);
    expect(activeEnv.value, BrijjEnv.production);

    await tester.tap(find.text('Staging'));
    await tester.pump();
    expect(activeEnv.value, BrijjEnv.staging);
  });
}
