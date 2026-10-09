import 'package:flutter_test/flutter_test.dart';
import 'package:scan_pull/transfer_model.dart';

void main() {
  test('Quick Transfer by item matches the IMS web request', () {
    final p = TransferProduct(493023, "Girl's/Accessories/NA")..serials.addAll({823727: '377127428326', 823728: '377127428426'});
    final o = quickTransferOrder(
      fromWarehouseId: 338,
      toWarehouseId: 262,
      scope: TransferScope.product,
      companyId: 99,
      date: DateTime(2026, 10, 9),
      products: [p],
      notes: 'to the floor',
    );
    expect([o['status'], o['type'], o['transferScope'], o['transferOrderProcessType'], o['date'], o['priority']], [1, 1, 2, 2, '2026-10-09', 2]);
    final item = (o['items'] as List).single as Map;
    expect([item['productId'], item['quantity'], item['status'], item['licensePlateId']], [493023, 2, 4, null]);
    expect(item['serials'], [
      {'productSerialId': 823727},
      {'productSerialId': 823728},
    ]);
  });

  test('Quick Transfer by license plate sends plates only', () {
    final o = quickTransferOrder(
      fromWarehouseId: 338,
      toWarehouseId: 262,
      scope: TransferScope.licensePlate,
      companyId: 99,
      date: DateTime(2026, 10, 9),
      licensePlateIds: [1847],
    );
    final item = (o['items'] as List).single as Map;
    expect([item['licensePlateId'], item['productId'], item['quantity'], item['serials']], [1847, null, null, isEmpty]);
  });

  test('the 1000-item Quick Transfer limit', () {
    final big = TransferProduct(1, 'x')..serials.addAll({for (var i = 0; i < 1001; i++) i: '$i'});
    expect(overQuickLimit([big]), isTrue);
    expect(overQuickLimit([TransferProduct(2, 'y')..serials[1] = 'a']), isFalse);
  });

  test('Quick Receive: lines are ready when every dispatched serial arrived', () {
    final dispatch = {
      'id': 775,
      'transferOrderId': 600,
      'items': [
        {
          'id': 455,
          'transferOrderItemId': 473,
          'productId': 10,
          'quantityDispatched': 2,
          'product': {'name': "Boy's Clothing/Shorts"},
          'serials': [
            {'productSerialId': 1, 'serialNumber': 'A'},
            {'productSerialId': 2, 'serialNumber': 'B'},
          ],
        },
        {'id': 456, 'transferOrderItemId': 474, 'licensePlateId': 1847, 'quantityDispatched': 0, 'serials': []},
      ],
    };
    final lines = receiveLines(dispatch);
    expect([lines[0].ready, lines[1].ready], [false, true]);
    lines[0].received.add('A');
    expect(lines[0].ready, isFalse);
    lines[0].received.add('B');
    expect(lines[0].ready, isTrue);

    final o = quickReceiveOrder(
      dispatch: dispatch,
      lines: lines,
      destinationId: 856,
      warehouseId: 262,
      companyId: 99,
      userId: 4063,
      date: DateTime(2026, 10, 9),
    );
    expect([o['transferDispatchOrderId'], o['transferOrderId'], o['processType'], o['status'], o['receivedByUserId'], o['receivedDate']], [
      775, 600, 2, 8, 4063, '2026-10-09',
    ]);
    final first = (o['items'] as List).first as Map;
    expect([first['transferDispatchOrderItemId'], first['transferOrderItemId'], first['quantityReceived'], first['destinationLocationId'], first['licensePlateAction']], [
      455, 473, 2, 856, 0,
    ]);
    expect((first['serials'] as List).map((s) => (s as Map)['productSerialId']).toSet(), {1, 2});
    final plate = (o['items'] as List).last as Map;
    expect([plate['licensePlateId'], plate['serials']], [1847, isEmpty]);
  });
}
