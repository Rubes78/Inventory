import 'package:flutter_test/flutter_test.dart';
import 'package:scan_pull/relocation_model.dart';
import 'package:scan_pull/work_model.dart';

Map<String, dynamic> wl(int id, int type, String created, List<Map<String, dynamic>> lines) => {
  'id': id,
  'type': type,
  'referenceNumber': 'WK-$id',
  'typeReferenceNumber': 'REF-$id',
  'createdAt': created,
  'worklistLineItems': lines,
};

Map<String, dynamic> task(int id, int type, int status, {Object? userId, bool active = true}) => {
  'id': id,
  'type': type,
  'status': status,
  'userId': userId,
  'userName': userId == null ? 'NotAssigned' : 'Someone',
  'active': active,
  'referenceId': 500 + id,
};

void main() {
  final worklists = [
    wl(1, WorkType.inventoryCount, '2026-10-01T10:00:00Z', [task(11, TaskType.physicalItemCount, TaskStatus.inProgress, userId: 7)]),
    wl(2, WorkType.movement, '2026-10-03T10:00:00Z', [task(21, TaskType.relocate, TaskStatus.notAssigned)]),
    wl(3, WorkType.transferOrder, '2026-10-02T10:00:00Z', [task(31, TaskType.pickOnly, TaskStatus.assigned, userId: 8)]),
    wl(4, WorkType.purchaseOrder, '2026-10-04T10:00:00Z', [task(41, TaskType.putaway, TaskStatus.completed, userId: 7)]),
    wl(5, WorkType.movement, '2026-10-05T10:00:00Z', [task(51, TaskType.relocate, TaskStatus.notAssigned, active: false)]),
  ];

  test('only active, unfinished task lines show (IMS handleWorklistsResponse)', () {
    expect(flattenWork(worklists).map((w) => w.worklistId), [1, 2, 3]);
  });

  test('filters and newest-first sort match the IMS Work screen', () {
    final items = flattenWork(worklists);
    expect(filterWork(items, WorkFilter.all, '7').map((w) => w.worklistId), [2, 3, 1]);
    expect(filterWork(items, WorkFilter.mine, '7').map((w) => w.worklistId), [1]);
    expect(filterWork(items, WorkFilter.unassigned, '7').map((w) => w.worklistId), [2]);
  });

  test('labels and handlers', () {
    final byId = {for (final w in flattenWork(worklists)) w.worklistId: w};
    expect(byId[1]!.actionLabel, 'Resume Cycle Count');
    expect(byId[1]!.handler, WorkHandler.count);
    expect(byId[2]!.actionLabel, 'Start Relocation');
    expect(byId[2]!.handler, WorkHandler.relocation);
    expect(byId[2]!.assignee, '');
    expect(byId[3]!.handler, WorkHandler.imsPage);
    expect(byId[3]!.imsPath, '/work-items');
  });

  group('relocation finish (IMS finishRelocating)', () {
    Map<String, dynamic> order(List<int> statuses) => {
      'id': 9,
      'status': OrderStatus.workInProgress,
      'items': [
        for (final s in statuses) {'status': s, 'sourceWarehouseLocationId': 856, 'destinationWarehouseLocationId': 1610},
      ],
    };
    Map<String, dynamic> work() => {
      'status': 2,
      'worklistLineItems': [
        {'status': 3},
      ],
    };

    test('all relocated → completed', () {
      final o = order([LineStatus.relocated, LineStatus.relocated]);
      final w = work();
      expect(finishRelocation(o, w, 262), OrderStatus.completed);
      expect([o['warehouseId'], w['status'], (w['worklistLineItems'] as List).first['status']], [262, 3, 4]);
    });

    test('some relocated → still in progress', () {
      final o = order([LineStatus.relocated, LineStatus.picked]);
      final w = work();
      expect(finishRelocation(o, w, 262), OrderStatus.workInProgress);
      expect([w['status'], (w['worklistLineItems'] as List).first['status']], [2, 3]);
    });

    test('none relocated → back to open, unassigned', () {
      final o = order([LineStatus.pending]);
      final w = work();
      expect(finishRelocation(o, w, 262), OrderStatus.open);
      expect([w['status'], (w['worklistLineItems'] as List).first['status']], [1, 1]);
    });

    test('line edits land in the order that gets saved', () {
      final o = order([LineStatus.pending]);
      final l = relocationLines(o).first;
      l.status = LineStatus.picked;
      l.setDestination(1593, 'Sales Floor');
      final saved = (o['items'] as List).first as Map;
      expect([saved['status'], saved['destinationWarehouseLocationId']], [LineStatus.picked, 1593]);
    });

    test('destination cannot be the source', () {
      final l = relocationLines(order([LineStatus.picked])).first;
      expect(l.setDestination(856, 'Sales Floor'), isNotNull);
      expect(l.setDestination(1593, 'Sales Floor'), isNull);
      expect([l.destinationId, l.destination], [1593, 'Sales Floor']);
    });
  });
}
