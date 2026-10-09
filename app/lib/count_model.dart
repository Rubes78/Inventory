/// Counting an IMS Inventory Count on the device — the same lines, expected
/// quantities and submit payload as the IMS web app's counting screen
/// (add-review-count), but scan-driven: each scanned barcode is routed to the line
/// it belongs to, and the InStock/Discard serials are worked out on submit.
library;

/// TrackInventoryOption.Serial in IMS.
const _serialTracking = 3;

/// InventoryCountingItemStatus.Counted.
const _counted = 2;

/// InventoryCountingItemSerialStatus: InStock / Discard.
const _inStock = 1, _discard = 2;

/// "Girl's/Dresses/NA/69081/128390/NA" → "Girl's › Dresses".
String shortProductName(String name) {
  final parts = name.split('/').where((p) => p.isNotEmpty && p != 'NA').toList();
  if (parts.length < 2) return name;
  return '${parts[0]} › ${parts[1]}';
}

/// One product at one location in the count.
class CountLine {
  CountLine({
    required this.itemId,
    required this.productId,
    required this.product,
    required this.sku,
    required this.locationId,
    required this.location,
    required this.expected,
    required this.serialized,
    required this.expectedSerials,
  });

  /// The count item this line reports against (InventoryCountItem id).
  final int itemId;
  final int productId;
  final String product;
  final String sku;
  final int? locationId;
  final String location;
  final int expected;
  final bool serialized;
  final List<String> expectedSerials;

  /// Barcodes scanned for this line (serialized products).
  final Set<String> scanned = {};

  /// Quantity entered by hand (non-serialized products).
  int manual = 0;

  String get key => '$productId@${locationId ?? 0}';

  int get actual => serialized ? scanned.length : manual;
  int get difference => actual - expected;

  /// Expected barcodes not scanned yet.
  List<String> get missing => [for (final s in expectedSerials) if (!scanned.contains(s)) s];

  /// Scanned barcodes IMS didn't expect here.
  List<String> get extra => [for (final s in scanned) if (!expectedSerials.contains(s)) s];

  /// The count line as the IMS web app submits it (ConfirmCount → finalPayload).
  /// Serials only cover the difference: extra barcodes found are InStock, expected
  /// ones not found are Discard.
  Map<String, dynamic> payload({required int countId, required Object userId}) {
    final diff = difference;
    final serials = !serialized || diff == 0
        ? const <Map<String, dynamic>>[]
        : diff > 0
        ? [
            for (final s in extra.take(diff)) {'inventoryCountingScopeItemId': itemId, 'serialNumber': s, 'status': _inStock},
          ]
        : [
            for (final s in missing.take(-diff))
              {'inventoryCountingScopeItemId': itemId, 'serialNumber': s, 'status': _discard},
          ];
    return {
      'id': itemId,
      'inventoryCountingId': countId,
      'productId': productId,
      'warehouseLocationId': locationId,
      'expectedCount': expected,
      'actualCount': actual,
      'status': _counted,
      'countedById': userId,
      'reviewedBy': userId,
      'InventoryCountingItemSerials': serials,
    };
  }
}

/// Builds the count's lines as the IMS web app does (loadLocationsForCurrentItem):
/// each product at each location where IMS has it on hand, narrowed to the count's
/// scope (specific locations/zones) and, for a recount, to its location.
/// [products] holds `GET /api/Products/{id}?WarehouseId=` for each product.
/// When [allowedLocations] is given, only those locations are counted (the app
/// counts sales floor and storage only — never Scan Pull).
List<CountLine> buildCountLines(
  Map<String, dynamic> count,
  Map<int, Map<String, dynamic>> products, {
  Set<int>? allowedLocations,
}) {
  final scope = count['scope'];
  final scopeItems = [for (final s in count['scopeItems'] as List? ?? const []) if (s is num) s.toInt()];
  final items = [for (final i in count['items'] as List? ?? const []) if (i is Map) i.cast<String, dynamic>()];
  final lines = <CountLine>[];
  final seen = <String>{};

  int? asInt(Object? v) => v is num ? v.toInt() : null;

  for (final item in items) {
    final productId = asInt(item['productId']);
    if (productId == null) continue;
    final product = products[productId] ?? (item['product'] as Map?)?.cast<String, dynamic>() ?? const {};
    final serialized = product['trackInventoryOption'] == _serialTracking;
    final itemLocation = asInt(item['warehouseLocationId']);
    final inventories = [for (final i in product['inventories'] as List? ?? const []) if (i is Map) i.cast<String, dynamic>()];
    var here = inventories.where((i) => (asInt(i['onHandQuantity']) ?? 0) > 0).toList();
    if ((scope == 2 || scope == 3) && scopeItems.isNotEmpty) {
      here = here.where((i) => scopeItems.contains(asInt(i['id']))).toList();
    }
    if (allowedLocations != null) {
      here = here.where((i) => allowedLocations.contains(asInt(i['id']))).toList();
    }
    if (item['isRecountScheduled'] == true && itemLocation != null) {
      here = here.where((i) => asInt(i['id']) == itemLocation).toList();
    }

    int itemIdFor(int? locationId) =>
        asInt(
          items.firstWhere(
            (i) => i['productId'] == productId && asInt(i['warehouseLocationId']) == locationId,
            orElse: () => item,
          )['id'],
        ) ??
        0;

    void add(int? locationId, String location, int expected, List<String> serials) {
      final line = CountLine(
        itemId: itemIdFor(locationId),
        productId: productId,
        product: '${product['name'] ?? (item['product'] as Map?)?['name'] ?? 'Product $productId'}',
        sku: '${product['sku'] ?? (item['product'] as Map?)?['sku'] ?? ''}',
        locationId: locationId,
        location: location,
        expected: expected,
        serialized: serialized,
        expectedSerials: serials,
      );
      if (seen.add(line.key)) lines.add(line);
    }

    if (inventories.isEmpty) {
      add(itemLocation, itemLocation == null ? 'Default location' : 'Location $itemLocation', asInt(item['expectedCount']) ?? 0, const []);
    } else if (here.isEmpty && itemLocation != null && (allowedLocations == null || allowedLocations.contains(itemLocation))) {
      final inv = inventories.firstWhere((i) => asInt(i['id']) == itemLocation, orElse: () => const {});
      add(itemLocation, '${inv['name'] ?? 'Location $itemLocation'}', asInt(item['expectedCount']) ?? 0, const []);
    } else {
      for (final inv in here) {
        add(asInt(inv['id']), '${inv['name'] ?? 'Location ${inv['id']}'}', asInt(inv['onHandQuantity']) ?? 0, [
          for (final s in inv['serials'] as List? ?? const [])
            if (s is Map && s['serialNumber'] != null) '${s['serialNumber']}',
        ]);
      }
    }
  }
  return lines;
}

enum ScanResult { counted, duplicate, unknown }

/// Routes a scanned barcode to the line expecting it. Unknown barcodes need an IMS
/// lookup ([placeExtra]) to find their product.
ScanResult routeScan(List<CountLine> lines, String barcode) {
  for (final l in lines) {
    if (l.scanned.contains(barcode)) return ScanResult.duplicate;
  }
  for (final l in lines) {
    if (l.serialized && l.expectedSerials.contains(barcode)) {
      l.scanned.add(barcode);
      return ScanResult.counted;
    }
  }
  return ScanResult.unknown;
}

/// Puts an unexpected barcode of [productId] (found by IMS at [locationId]) on that
/// product's line — the one at that location if the count has it, else the first.
/// Returns the line, or null if the product isn't part of this count.
CountLine? placeExtra(List<CountLine> lines, String barcode, int productId, int? locationId) {
  final mine = lines.where((l) => l.productId == productId && l.serialized).toList();
  if (mine.isEmpty) return null;
  final line = mine.firstWhere((l) => l.locationId == locationId, orElse: () => mine.first);
  line.scanned.add(barcode);
  return line;
}

/// Saved progress: what was scanned or entered per line, to resume after a restart.
Map<String, dynamic> progressToJson(List<CountLine> lines) => {
  for (final l in lines)
    if (l.scanned.isNotEmpty || l.manual != 0) l.key: {'scanned': l.scanned.toList(), 'manual': l.manual},
};

void progressFromJson(List<CountLine> lines, Map<String, dynamic> j) {
  for (final l in lines) {
    final p = j[l.key];
    if (p is! Map) continue;
    l.scanned.addAll([for (final s in p['scanned'] as List? ?? const []) '$s']);
    l.manual = (p['manual'] as num?)?.toInt() ?? 0;
  }
}
