import 'package:flutter_test/flutter_test.dart';
import 'package:scan_pull/count_model.dart';

Map<String, dynamic> product(int id, List<Map<String, dynamic>> inventories, {int track = 3}) => {
  'id': id,
  'name': "Girl's/Dresses/NA/69081/128390/NA",
  'sku': 'TPM$id',
  'trackInventoryOption': track,
  'inventories': inventories,
};

Map<String, dynamic> inv(int id, String name, List<String> serials) => {
  'id': id,
  'name': name,
  'onHandQuantity': serials.length,
  'serials': [for (final s in serials) {'serialNumber': s}],
};

void main() {
  final count = {
    'id': 50,
    'scope': 1,
    'items': [
      {'id': 501, 'productId': 1, 'expectedCount': 3, 'warehouseLocationId': null},
      {'id': 502, 'productId': 2, 'expectedCount': 5, 'warehouseLocationId': null},
    ],
  };
  final products = {
    1: product(1, [inv(856, 'Sales Floor', ['A1', 'A2']), inv(1610, 'Scan Pull - Memphis', ['A3'])]),
    2: product(2, [inv(856, 'Sales Floor', ['x', 'x', 'x', 'x', 'x'])], track: 1),
  };

  test('lines per product per location, like the IMS web app', () {
    final lines = buildCountLines(count, products);
    expect([for (final l in lines) '${l.productId}@${l.location}:${l.expected}:${l.serialized}'], [
      '1@Sales Floor:2:true',
      '1@Scan Pull - Memphis:1:true',
      '2@Sales Floor:5:false',
    ]);
    expect(lines.first.itemId, 501);
    expect(shortProductName(lines.first.product), "Girl's › Dresses");
  });

  test('specific-locations scope keeps only the scoped locations', () {
    final scoped = {...count, 'scope': 2, 'scopeItems': [856]};
    final lines = buildCountLines(scoped, products);
    expect(lines.map((l) => l.location).toSet(), {'Sales Floor'});
  });

  test('scans route to lines; duplicates and unknowns are reported', () {
    final lines = buildCountLines(count, products);
    expect(routeScan(lines, 'A1'), ScanResult.counted);
    expect(routeScan(lines, 'A1'), ScanResult.duplicate);
    expect(routeScan(lines, 'A3'), ScanResult.counted);
    expect(routeScan(lines, 'NEW1'), ScanResult.unknown);
    // IMS says NEW1 is product 1 in location 856 → counted on that line as extra.
    expect(placeExtra(lines, 'NEW1', 1, 856)?.location, 'Sales Floor');
    expect(placeExtra(lines, 'OTHER', 99, 856), isNull);
    expect(routeScan(lines, 'NEW1'), ScanResult.duplicate);
  });

  test('payload: short lines discard the missing serials, over lines add the extras', () {
    final lines = buildCountLines(count, products);
    final floor = lines[0], pulled = lines[1], plain = lines[2];
    routeScan(lines, 'A1'); // floor: 1 of 2 → A2 discarded
    placeExtra(lines, 'B9', 1, 1610);
    routeScan(lines, 'A3'); // pulled: 2 of 1 → B9 in stock
    plain.manual = 4;

    final p1 = floor.payload(countId: 50, userId: 7);
    expect([p1['id'], p1['expectedCount'], p1['actualCount'], p1['status'], p1['warehouseLocationId']], [501, 2, 1, 2, 856]);
    expect(p1['InventoryCountingItemSerials'], [
      {'inventoryCountingScopeItemId': 501, 'serialNumber': 'A2', 'status': 2},
    ]);
    final p2 = pulled.payload(countId: 50, userId: 7);
    expect(p2['actualCount'], 2);
    expect(p2['InventoryCountingItemSerials'], [
      {'inventoryCountingScopeItemId': 501, 'serialNumber': 'B9', 'status': 1},
    ]);
    final p3 = plain.payload(countId: 50, userId: 7);
    expect([p3['id'], p3['actualCount'], p3['InventoryCountingItemSerials']], [502, 4, isEmpty]);
  });

  test('only allowed locations (sales floor / storage) are counted — never Scan Pull', () {
    final lines = buildCountLines(count, products, allowedLocations: {856});
    expect(lines.map((l) => l.location).toSet(), {'Sales Floor'});
    // A product whose only stock is in Scan Pull gets no line at all.
    final pulledOnly = {
      'id': 51,
      'scope': 1,
      'items': [
        {'id': 601, 'productId': 3, 'expectedCount': 1, 'warehouseLocationId': 1610},
      ],
    };
    final p3 = {3: product(3, [inv(1610, 'Scan Pull - Memphis', ['P1'])])};
    expect(buildCountLines(pulledOnly, p3, allowedLocations: {856}), isEmpty);
  });

  test('progress survives a restart', () {
    final lines = buildCountLines(count, products);
    routeScan(lines, 'A2');
    lines[2].manual = 3;
    final saved = progressToJson(lines);
    final again = buildCountLines(count, products);
    progressFromJson(again, saved);
    expect(again[0].scanned, {'A2'});
    expect(again[2].manual, 3);
  });
}
