/// The IMS mobile "Work" list, mirrored from the IMS web app (work-items): which
/// task lines show, how they're labelled and filtered, and where each one opens.
library;

/// WorklistType (IMS).
abstract final class WorkType {
  static const salesOrder = 1,
      purchaseOrder = 2,
      movement = 3,
      transferOrder = 4,
      inventoryCount = 5,
      transferReceiveOrder = 6,
      transferDispatchOrder = 7,
      returnOrder = 8,
      replenishment = 9;
}

/// WorklistItemType — the task (IMS).
abstract final class TaskType {
  static const pickOnly = 1,
      packOnly = 2,
      shipOnly = 3,
      pickAndPack = 4,
      pickPackAndShip = 5,
      receive = 6,
      putaway = 7,
      receivePutaway = 8,
      relocate = 9,
      replenish = 10,
      physicalItemCount = 11,
      recountItem = 12;
}

/// WorklistItemStatus (IMS).
abstract final class TaskStatus {
  static const notAssigned = 1, assigned = 2, inProgress = 3, completed = 4, cancelled = 5;
}

enum WorkFilter { all, mine, unassigned }

/// How the app handles a task: natively, or by opening the IMS page in-app.
enum WorkHandler { count, relocation, imsPage }

/// One task line of a worklist, as the IMS Work screen lists it.
class WorkItem {
  WorkItem(this.worklist, this.line);

  final Map<String, dynamic> worklist;
  final Map<String, dynamic> line;

  int get worklistId => (worklist['id'] as num).toInt();
  int get lineId => (line['id'] as num?)?.toInt() ?? 0;
  int get workType => (worklist['type'] as num?)?.toInt() ?? 0;
  int get taskType => (line['type'] as num?)?.toInt() ?? 0;
  int get status => (line['status'] as num?)?.toInt() ?? 0;
  String get userId => '${line['userId'] ?? ''}';

  /// The IMS record the task works on (movement order, count, …).
  int? get referenceId => (line['referenceId'] as num?)?.toInt();

  /// e.g. "WK-MV-596JYAEO".
  String get ref => '${worklist['referenceNumber'] ?? ''}';

  /// e.g. "IC-99-260630-0003" or "MO-99-…".
  String get typeRef => '${worklist['typeReferenceNumber'] ?? ''}';

  String get typeName => '${worklist['typeName'] ?? ''}';

  /// Who the task is with — IMS sends the text "NotAssigned" when nobody.
  String get assignee => '${line['userName'] ?? ''}'.replaceAll('NotAssigned', '').trim();

  DateTime get createdAt => DateTime.tryParse('${worklist['createdAt']}')?.toLocal() ?? DateTime(2000);

  int get productCount => (worklist['productCount'] as num?)?.toInt() ?? 0;

  bool isMine(String me) => userId == me;
  bool get isUnassigned => status == TaskStatus.notAssigned;
  bool get inProgress => status == TaskStatus.inProgress;

  /// The task's name, as on the IMS action button.
  String get taskName => switch (taskType) {
    TaskType.pickOnly || TaskType.pickAndPack || TaskType.pickPackAndShip => 'Picking',
    TaskType.packOnly => 'Packing',
    TaskType.shipOnly => 'Shipping',
    TaskType.receive || TaskType.receivePutaway => 'Receiving',
    TaskType.putaway => 'Putaway',
    TaskType.relocate => 'Relocation',
    TaskType.replenish => 'Replenishment',
    TaskType.physicalItemCount => 'Cycle Count',
    TaskType.recountItem => 'Recount Items',
    _ => 'Task',
  };

  /// "Start Cycle Count" / "Resume Relocation" (IMS getActionLabel).
  String get actionLabel => '${inProgress ? 'Resume' : 'Start'} $taskName';

  WorkHandler get handler {
    if (workType == WorkType.inventoryCount &&
        (taskType == TaskType.physicalItemCount || taskType == TaskType.recountItem)) {
      return WorkHandler.count;
    }
    if (workType == WorkType.movement && taskType == TaskType.relocate) return WorkHandler.relocation;
    return WorkHandler.imsPage;
  }

  /// The IMS web page for this task (IMS onAction routes). Dispatch tasks (pick /
  /// pack / ship) need the IMS work list to hand them over, so they open there.
  String get imsPath {
    final id = worklistId;
    switch (workType) {
      case WorkType.purchaseOrder:
        return taskType == TaskType.putaway ? '/movements/putaway/overview?Id=$id' : '/purchase?Id=$id';
      case WorkType.transferReceiveOrder:
        return '/transfer?Id=$id&taskLineItemId=$lineId';
      case WorkType.movement:
        return taskType == TaskType.replenish ? '/movements/replenish?Id=$id' : '/movements/relocate?Id=$id';
      case WorkType.inventoryCount:
        return '/counting/counting/start-inventory-count?Id=$id';
      default:
        return '/work-items';
    }
  }
}

/// Every open task line, as the IMS Work screen builds its list
/// (handleWorklistsResponse): active lines that aren't completed or cancelled.
List<WorkItem> flattenWork(List<Map<String, dynamic>> worklists) => [
  for (final w in worklists)
    for (final l in w['worklistLineItems'] as List? ?? const [])
      if (l is Map &&
          l['active'] == true &&
          l['status'] != TaskStatus.completed &&
          l['status'] != TaskStatus.cancelled)
        WorkItem(w, l.cast<String, dynamic>()),
];

/// The IMS Work screen's filter and sort (newest first by default).
List<WorkItem> filterWork(List<WorkItem> items, WorkFilter filter, String me, {bool newestFirst = true}) {
  final shown = items.where(
    (i) => switch (filter) {
      WorkFilter.all => true,
      WorkFilter.mine => i.isMine(me),
      WorkFilter.unassigned => i.isUnassigned,
    },
  ).toList();
  shown.sort((a, b) => newestFirst ? b.createdAt.compareTo(a.createdAt) : a.createdAt.compareTo(b.createdAt));
  return shown;
}
