import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'brand.dart';
import 'tpm_api.dart';

String _money(double v) => '\$${v.toStringAsFixed(2)}';

String _when(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '${t.month}/${t.day}/${t.year % 100} $h:${two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// One submit made on this device (either destination), kept so the user can see
/// what was done without the web portal. TPM Scan Pull leaves no movement order, so
/// this is the only in-app record of those.
class ActivityEntry {
  ActivityEntry({
    required this.at,
    required this.user,
    required this.company,
    required this.env,
    required this.destination,
    required this.reason,
    required this.items,
  });

  final DateTime at;
  final String user;
  final String company;
  final String env;
  final String destination;
  final String reason;
  final List<ActivityItem> items;

  int get pulled => items.where((i) => i.error == null).length;
  int get skipped => items.where((i) => (i.error ?? '').startsWith('Skipped')).length;
  int get failed => items.length - pulled - skipped;
  double get value => items.where((i) => i.error == null).fold(0, (t, i) => t + i.price);

  /// Movement order references in this submit's notes (IMS destination only).
  List<String> get refs => {
    for (final i in items)
      for (final m in RegExp(r'MO-[\w-]+').allMatches(i.note ?? '')) m.group(0)!,
  }.toList();

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'user': user,
    'company': company,
    'env': env,
    'destination': destination,
    'reason': reason,
    'items': [for (final i in items) i.toJson()],
  };

  static ActivityEntry fromJson(Map<String, dynamic> j) => ActivityEntry(
    at: DateTime.tryParse('${j['at']}') ?? DateTime(2000),
    user: '${j['user'] ?? ''}',
    company: '${j['company'] ?? ''}',
    env: '${j['env'] ?? ''}',
    destination: '${j['destination'] ?? ''}',
    reason: '${j['reason'] ?? ''}',
    items: [for (final i in j['items'] as List? ?? const []) ActivityItem.fromJson((i as Map).cast<String, dynamic>())],
  );
}

class ActivityItem {
  ActivityItem({required this.barcode, this.error, this.note, this.description = '', this.price = 0});

  final String barcode;
  final String? error;
  final String? note;

  /// e.g. "Girl's › Accessories", as it looked when submitted.
  final String description;
  final double price;

  Map<String, dynamic> toJson() => {
    'barcode': barcode,
    'error': error,
    'note': note,
    'description': description,
    'price': price,
  };

  static ActivityItem fromJson(Map<String, dynamic> j) => ActivityItem(
    barcode: '${j['barcode']}',
    error: j['error'] as String?,
    note: j['note'] as String?,
    description: '${j['description'] ?? ''}',
    price: (j['price'] as num?)?.toDouble() ?? 0,
  );
}

/// The device's submit log, newest first, capped at [_max] entries. Kept across
/// sign-outs (it's an audit trail); each entry names who submitted it.
class ActivityLog {
  static const _max = 200;

  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/activity_log.json');

  static Future<List<ActivityEntry>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      return [
        for (final j in jsonDecode(await f.readAsString()) as List)
          ActivityEntry.fromJson((j as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(ActivityEntry entry) async {
    final all = [entry, ...await load()].take(_max).toList();
    await (await _file()).writeAsString(jsonEncode([for (final e in all) e.toJson()]));
  }
}

/// Status colors shared by both tabs.
Color _statusColor(int moveStatus) => switch (moveStatus) {
  MoveStatus.completed => statusSuccess,
  MoveStatus.cancelled || MoveStatus.failed => statusDanger,
  _ => statusWarning,
};

/// History: IMS movement orders for the Scan Pull warehouse, and this device's submits.
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.session, this.warehouseId, this.warehouseName});

  final BrijjSession session;

  /// The Scan Pull location's warehouse; null when the company has none (TPM mode).
  final int? warehouseId;
  final String? warehouseName;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('History'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Movement orders'),
              Tab(text: 'This device'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            warehouseId == null
                ? const _Empty(
                    icon: Icons.info_outline,
                    title: 'No IMS Scan Pull location',
                    subtitle: 'Pulls go straight to TPM, which keeps no movement orders. See "This device".',
                  )
                : _MovementOrdersTab(session: session, warehouseId: warehouseId!, warehouseName: warehouseName ?? ''),
            _DeviceTab(session: session),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      const SizedBox(height: 32),
      ListTile(
        leading: Icon(icon, size: 32),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
      ),
    ],
  );
}

class _MovementOrdersTab extends StatefulWidget {
  const _MovementOrdersTab({required this.session, required this.warehouseId, required this.warehouseName});

  final BrijjSession session;
  final int warehouseId;
  final String warehouseName;

  @override
  State<_MovementOrdersTab> createState() => _MovementOrdersTabState();
}

class _MovementOrdersTabState extends State<_MovementOrdersTab> with AutomaticKeepAliveClientMixin {
  final _orders = <MovementOrderSummary>[];
  int _page = 0;
  int _pages = 1;
  bool _loading = false;
  String? _error;
  bool _scanPullOnly = true;
  bool _mine = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    _orders.clear();
    _page = 0;
    _pages = 1;
    await _more();
    // IMS pages from the oldest end, so the newest page can be nearly empty: top it up.
    if (_orders.length < 15 && _error == null) await _more();
  }

  Future<void> _more() async {
    if (_loading || _page >= _pages) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = TpmApi(widget.session.env);
    try {
      final page = await api.movementOrders(widget.session, widget.warehouseId, page: _page + 1);
      _orders.addAll(page.orders);
      _page++;
      _pages = page.pages;
    } on TpmApiException catch (e) {
      _error = e is OfflineException ? 'Offline — movement orders need a connection.' : e.message;
    } finally {
      api.close();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final shown = _orders
        .where((o) => !_scanPullOnly || o.isScanPull)
        .where((o) => !_mine || o.createdById == widget.session.userId)
        .toList();
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(widget.warehouseName, style: const TextStyle(fontWeight: FontWeight.w600)),
                FilterChip(
                  label: const Text('Scan Pull only'),
                  selected: _scanPullOnly,
                  onSelected: (v) => setState(() => _scanPullOnly = v),
                ),
                FilterChip(label: const Text('Mine'), selected: _mine, onSelected: (v) => setState(() => _mine = v)),
              ],
            ),
          ),
          if (_error != null)
            ListTile(
              leading: const Icon(Icons.cloud_off, color: statusWarning),
              title: Text(_error!),
              trailing: TextButton(onPressed: _refresh, child: const Text('Retry')),
            ),
          if (shown.isEmpty && !_loading && _error == null)
            const _Empty(icon: Icons.inbox, title: 'No movement orders here yet'),
          for (final o in shown) _orderTile(o),
          if (_loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_page < _pages && _error == null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton(onPressed: _more, child: const Text('Load older')),
            ),
        ],
      ),
    );
  }

  Widget _orderTile(MovementOrderSummary o) {
    final color = _statusColor(o.status);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: ListTile(
        title: Row(
          children: [
            Expanded(
              child: Text(o.ref, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Text(
              MoveStatus.label(o.status),
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        subtitle: Text(
          [
            o.reason.isEmpty ? '(no reason)' : o.reason,
            '${o.products} item(s)${o.totalPrice > 0 ? ' · ${_money(o.totalPrice)}' : ''} · ${o.relocationLabel}',
            '${_when(o.createdAt)} · ${o.createdBy}'
                '${o.completedBy != null && o.completedBy != o.createdBy ? ' · completed by ${o.completedBy}' : ''}',
          ].join('\n'),
        ),
        isThreeLine: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => MovementOrderDetailPage(session: widget.session, orderId: o.id)),
        ),
      ),
    );
  }
}

/// Everything about one movement order: header, then each line with its barcodes.
class MovementOrderDetailPage extends StatefulWidget {
  const MovementOrderDetailPage({super.key, required this.session, required this.orderId});

  final BrijjSession session;
  final int orderId;

  @override
  State<MovementOrderDetailPage> createState() => _MovementOrderDetailPageState();
}

class _MovementOrderDetailPageState extends State<MovementOrderDetailPage> {
  MovementOrderDetail? _order;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final api = TpmApi(widget.session.env);
    try {
      final o = await api.movementOrder(widget.session, widget.orderId);
      if (mounted) setState(() => _order = o);
    } on TpmApiException catch (e) {
      if (mounted) setState(() => _error = e is OfflineException ? 'Offline — try again when connected.' : e.message);
    } finally {
      api.close();
    }
  }

  Widget _field(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 110, child: Text(label, style: const TextStyle(color: brijjText))),
        Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final o = _order;
    final s = o?.summary;
    return Scaffold(
      appBar: AppBar(
        title: Text(s?.ref ?? 'Movement order'),
        actions: [IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: o == null || s == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _field('Status', MoveStatus.label(s.status)),
                _field('Reason', s.reason.isEmpty ? '—' : s.reason),
                if (s.instruction.isNotEmpty) _field('Note', s.instruction),
                _field('Type', s.relocationLabel),
                _field('Items', '${s.products}${s.totalPrice > 0 ? ' · ${_money(s.totalPrice)}' : ''}'),
                _field('Warehouse', s.warehouse.isEmpty ? '—' : s.warehouse),
                _field('Created', '${_when(s.createdAt)} · ${s.createdBy}'),
                _field(
                  'Completed',
                  s.completedAt == null ? '—' : '${_when(s.completedAt!)}${s.completedBy == null ? '' : ' · ${s.completedBy}'}',
                ),
                const Divider(height: 32),
                Text('Lines (${o.lines.length})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                for (final l in o.lines) _line(l),
              ],
            ),
    );
  }

  Widget _line(MovementOrderLine l) {
    final done = l.status == 3;
    final cancelled = l.status == 4;
    // Week-color and location orders carry thousands of serials; show a sample.
    final shown = l.serials.take(50).toList();
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  done ? Icons.check_circle : (cancelled ? Icons.cancel : Icons.hourglass_top),
                  color: done ? statusSuccess : (cancelled ? statusDanger : statusWarning),
                  size: 20,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.product.isEmpty ? '${l.quantity} item(s)' : l.product,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(l.statusLabel),
              ],
            ),
            Text('${l.from} → ${l.to}'),
            if (shown.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SelectableText(
                  shown.join('  ') + (l.serials.length > shown.length ? '  … +${l.serials.length - shown.length} more' : ''),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DeviceTab extends StatefulWidget {
  const _DeviceTab({required this.session});

  final BrijjSession session;

  @override
  State<_DeviceTab> createState() => _DeviceTabState();
}

class _DeviceTabState extends State<_DeviceTab> with AutomaticKeepAliveClientMixin {
  List<ActivityEntry>? _entries;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    ActivityLog.load().then((e) {
      // Only this company and environment.
      final mine = e.where((x) => x.company == widget.session.companyName && x.env == widget.session.env.label).toList();
      if (mounted) setState(() => _entries = mine);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final entries = _entries;
    if (entries == null) return const Center(child: CircularProgressIndicator());
    if (entries.isEmpty) {
      return const _Empty(icon: Icons.history, title: 'Nothing submitted from this device yet');
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [for (final e in entries) _entryTile(e)],
    );
  }

  Widget _entryTile(ActivityEntry e) {
    final problem = e.failed > 0;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: ListTile(
        leading: Icon(
          problem ? Icons.error : Icons.check_circle,
          color: problem ? statusDanger : statusSuccess,
        ),
        title: Text(
          '${e.pulled} pulled${e.value > 0 ? ' · ${_money(e.value)}' : ''}'
          '${e.skipped > 0 ? ' · ${e.skipped} skipped' : ''}${e.failed > 0 ? ' · ${e.failed} failed' : ''}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            '${_when(e.at)} · ${e.user}',
            'to ${e.destination}${e.reason.isEmpty ? '' : ' · ${e.reason}'}',
            if (e.refs.isNotEmpty) e.refs.join(', '),
          ].join('\n'),
        ),
        isThreeLine: true,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _EntryPage(entry: e))),
      ),
    );
  }
}

/// One device submit: every barcode and what happened to it.
class _EntryPage extends StatelessWidget {
  const _EntryPage({required this.entry});

  final ActivityEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final items = [...e.items.where((i) => i.error != null), ...e.items.where((i) => i.error == null)];
    return Scaffold(
      appBar: AppBar(title: Text(_when(e.at))),
      body: ListView(
        children: [
          ListTile(
            title: Text('${e.pulled} of ${e.items.length} pulled · ${_money(e.value)}'),
            subtitle: Text(
              'by ${e.user} · to ${e.destination}${e.reason.isEmpty ? '' : '\n${e.reason}'}',
            ),
          ),
          const Divider(height: 1),
          for (final i in items)
            ListTile(
              leading: Icon(
                i.error == null ? Icons.check_circle : Icons.error,
                color: i.error == null ? statusSuccess : statusDanger,
              ),
              title: Text(i.barcode, style: const TextStyle(fontFamily: 'monospace')),
              subtitle: Text(
                [
                  if (i.description.isNotEmpty) '${i.description}${i.price > 0 ? ' · ${_money(i.price)}' : ''}',
                  i.error ?? (i.note == null ? 'Pulled' : 'Pulled · ${i.note}'),
                ].join('\n'),
              ),
            ),
        ],
      ),
    );
  }
}
