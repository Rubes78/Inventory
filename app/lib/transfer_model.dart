/// Quick Transfer and Quick Receive requests, built the way the IMS web app
/// builds them (quick-transfer-order-wrapper submitTransferOrder, and
/// quick-transfer-receive createQuickTransferOrder).
library;

/// TransferScope.
abstract final class TransferScope {
  static const licensePlate = 1, product = 2;
}

/// IMS refuses Quick Transfer/Receive for more than this many product units
/// (the web app offers a regular transfer instead).
const quickLimit = 1000;

String isoDay(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A product being transferred: its serials (productSerialId → barcode).
class TransferProduct {
  TransferProduct(this.productId, this.name);

  final int productId;
  final String name;
  final Map<int, String> serials = {};

  int get quantity => serials.length;
}

/// POST /api/TransferOrders body for a Quick Transfer.
Map<String, dynamic> quickTransferOrder({
  required int fromWarehouseId,
  required int toWarehouseId,
  required int scope,
  required Object companyId,
  required DateTime date,
  int priority = 2,
  String notes = '',
  List<TransferProduct> products = const [],
  List<int> licensePlateIds = const [],
}) => {
  'fromWarehouseId': fromWarehouseId,
  'toWarehouseId': toWarehouseId,
  'transferScope': scope,
  'status': 1, // Open
  'date': isoDay(date),
  'expectedDeliveryDate': isoDay(date),
  'priority': priority,
  'notes': notes,
  'type': 1, // StockTransfer
  'companyId': companyId,
  'transferOrderProcessType': 2, // Quick
  'items': scope == TransferScope.product
      ? [
          for (final p in products)
            {
              'id': 0,
              'transferOrderId': 0,
              'productId': p.productId,
              'quantity': p.quantity,
              'licensePlateId': null,
              'remarks': '',
              'status': 4, // Completed
              'serials': [for (final id in p.serials.keys) {'productSerialId': id}],
              'itemLocationQuantities': [],
            },
        ]
      : [
          for (final lp in licensePlateIds)
            {
              'id': 0,
              'transferOrderId': 0,
              'productId': null,
              'quantity': null,
              'licensePlateId': lp,
              'remarks': '',
              'status': 4,
              'serials': [],
              'itemLocationQuantities': [],
            },
        ],
};

bool overQuickLimit(List<TransferProduct> products) => products.fold<int>(0, (t, p) => t + p.quantity) > quickLimit;

/// One dispatched line of a transfer, with what was received against it.
class ReceiveLine {
  ReceiveLine(this.json)
    : dispatched = {
        for (final s in json['serials'] as List? ?? const [])
          if (s is Map && s['serialNumber'] != null) '${s['serialNumber']}': (s['productSerialId'] as num?)?.toInt() ?? 0,
      };

  final Map<String, dynamic> json;

  /// Dispatched serials: barcode → productSerialId.
  final Map<String, int> dispatched;

  /// Barcodes confirmed as arrived.
  final Set<String> received = {};

  int get itemId => (json['id'] as num?)?.toInt() ?? 0;
  int? get productId => (json['productId'] as num?)?.toInt();
  int? get licensePlateId => (json['licensePlateId'] as num?)?.toInt();
  int get quantity => (json['quantityDispatched'] as num?)?.toInt() ?? 0;
  String get product => '${(json['product'] as Map?)?['name'] ?? ''}';
  String? get licensePlate => (json['licensePlate'] as Map?)?['referenceNumber'] as String?;

  bool get isPlate => licensePlateId != null;

  /// A product line is ready when every dispatched serial was received (IMS Quick
  /// Receive requires receivedSerials.length == quantity); a plate is received whole.
  bool get ready => isPlate || (quantity > 0 && received.length == quantity);
}

List<ReceiveLine> receiveLines(Map<String, dynamic> dispatch) => [
  for (final i in dispatch['items'] as List? ?? const [])
    if (i is Map) ReceiveLine(i.cast<String, dynamic>()),
];

/// POST /api/TransferReceiveOrders body for a Quick Receive of [dispatch] into
/// [destinationId]. Plates are kept whole (licensePlateAction 0).
Map<String, dynamic> quickReceiveOrder({
  required Map<String, dynamic> dispatch,
  required List<ReceiveLine> lines,
  required int destinationId,
  required int warehouseId,
  required Object companyId,
  required Object userId,
  required DateTime date,
}) => {
  'transferDispatchOrderId': dispatch['id'],
  'transferOrderId': dispatch['transferOrderId'] ?? 0,
  'processType': 2, // Quick
  'receivedDate': isoDay(date),
  'companyId': companyId,
  'status': 8, // Received
  'receivedByUserId': userId,
  'items': [
    for (final l in lines)
      {
        'id': 0,
        'transferDispatchOrderItemId': l.itemId,
        'transferOrderItemId': l.json['transferOrderItemId'] ?? 0,
        'productId': l.productId,
        'licensePlateAction': 0,
        'licensePlateId': l.licensePlateId,
        'quantityReceived': l.quantity,
        'destinationLocationId': destinationId,
        'discrepancy': null,
        'serials': [
          for (final b in l.received)
            {'productId': l.productId ?? 0, 'warehouseId': warehouseId, 'productSerialId': l.dispatched[b], 'serialNumber': b},
        ],
      },
  ],
};
