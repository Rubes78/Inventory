/// The Relocation work task, mirrored from the IMS web app (movements/relocate,
/// app-process-relocation): each movement order line goes Pending → Picked →
/// Relocated, and finishing saves the order and its work item with the statuses
/// IMS uses.
library;

/// MovementOrderItemStatus.
abstract final class LineStatus {
  static const pending = 1, picked = 2, relocated = 3, cancelled = 4;
}

/// MovementOrderStatus (as used here).
abstract final class OrderStatus {
  static const open = 1, workInProgress = 2, queued = 3, processing = 4, completed = 5, cancelled = 6;
}

/// Worklist status / worklist item status values the relocation task sets.
abstract final class _Work {
  static const pending = 1, inProgress = 2, completed = 3;
  static const itemNotAssigned = 1, itemInProgress = 3, itemCompleted = 4;
}

/// A movement order line, read from IMS's movement order JSON (kept by reference
/// so status/destination edits go straight into the order that gets saved).
class RelocationLine {
  RelocationLine(this.json);

  final Map<String, dynamic> json;

  int get status => (json['status'] as num?)?.toInt() ?? LineStatus.pending;
  set status(int v) => json['status'] = v;

  String get product => '${(json['product'] as Map?)?['name'] ?? ''}';
  String get sku => '${(json['product'] as Map?)?['sku'] ?? ''}';
  int get quantity => (json['quantity'] as num?)?.toInt() ?? 0;
  int? get sourceId => (json['sourceWarehouseLocationId'] as num?)?.toInt();
  String get source => '${(json['sourceLocation'] as Map?)?['name'] ?? (sourceId == null ? '—' : 'Location $sourceId')}';
  int? get destinationId => (json['destinationWarehouseLocationId'] as num?)?.toInt();
  String get destination => '${(json['destinationLocation'] as Map?)?['name'] ?? (destinationId == null ? '' : 'Location $destinationId')}';

  List<String> get serials => [
    for (final s in json['serials'] as List? ?? const [])
      if (s is Map && s['serialNumber'] != null) '${s['serialNumber']}',
  ];

  /// Licence plate reference, for licence-plate relocations.
  String? get licensePlate => (json['licensePlate'] as Map?)?['referenceNumber'] as String?;

  /// Sets the destination (the IMS web app refuses the source location).
  String? setDestination(int id, String name) {
    if (id == sourceId) return 'Destination cannot be the same as the source location.';
    json['destinationWarehouseLocationId'] = id;
    json['destinationLocation'] = {...?(json['destinationLocation'] as Map?)?.cast<String, dynamic>(), 'id': id, 'name': name};
    return null;
  }
}

/// The order's lines, ready to edit. Call once per loaded order: each line is
/// copied into a plain editable map and the copies replace the order's lines, so
/// every edit lands in the order that gets saved.
List<RelocationLine> relocationLines(Map<String, dynamic> order) {
  final raw = order['items'];
  if (raw is! List) return [];
  final items = <dynamic>[
    for (final i in raw)
      if (i is Map) Map<String, dynamic>.from(i),
  ];
  order['items'] = items;
  return [for (final i in items) RelocationLine(i as Map<String, dynamic>)];
}

/// Finishing the task (IMS finishRelocating): sets the order's and work item's
/// statuses from how many lines were relocated, ready to be saved with
/// PUT MovementOrders/{id} and PUT Worklists/{id}. Returns the order status set.
int finishRelocation(Map<String, dynamic> order, Map<String, dynamic> worklist, int warehouseId) {
  final statuses = [
    for (final i in order['items'] as List? ?? const [])
      if (i is Map) (i['status'] as num?)?.toInt() ?? LineStatus.pending,
  ];
  final all = statuses.isNotEmpty && statuses.every((s) => s == LineStatus.relocated);
  final some = statuses.any((s) => s == LineStatus.relocated);
  final (orderStatus, workStatus, itemStatus) = all
      ? (OrderStatus.completed, _Work.completed, _Work.itemCompleted)
      : some
      ? (OrderStatus.workInProgress, _Work.inProgress, _Work.itemInProgress)
      : (OrderStatus.open, _Work.pending, _Work.itemNotAssigned);
  order['status'] = orderStatus;
  order['warehouseId'] = warehouseId;
  worklist['status'] = workStatus;
  for (final l in worklist['worklistLineItems'] as List? ?? const []) {
    if (l is Map) l['status'] = itemStatus;
  }
  return orderStatus;
}
