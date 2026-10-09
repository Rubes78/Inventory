import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_pull/user_photo.dart';

void main() {
  test('initials from the full name', () {
    expect(UserAvatar.initials('Automation User'), 'AU');
    expect(UserAvatar.initials('FirstWhiskers LastWhiskers'), 'FL');
    expect(UserAvatar.initials('Cher'), 'C');
    expect(UserAvatar.initials('  '), '?');
  });

  testWidgets('avatar shows initials when there is no picture', (tester) async {
    UserPhoto.bytes.value = null;
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UserAvatar(name: 'Automation User'))));
    expect(find.text('AU'), findsOneWidget);
  });
}
