import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'brand.dart';
import 'history.dart';
import 'ims_web.dart';
import 'inventory_count.dart';
import 'license_plates.dart';
import 'main.dart' show LookupCache, ScanListPage, ScanStore;
import 'pending_moves.dart';
import 'quick_relocation.dart';
import 'relocation_task.dart';
import 'tpm_api.dart';
import 'transfers.dart';
import 'updater.dart';
import 'user_photo.dart';
import 'work_model.dart';

/// The warehouse the app works in, as the IMS mobile view's warehouse switcher:
/// the user's IMS default unless they picked another (remembered on the device).
class WarehouseStore {
  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/warehouse.json');

  static Future<Warehouse?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return Warehouse((j['id'] as num).toInt(), '${j['name']}');
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(Warehouse? w) async {
    final f = await _file();
    if (w == null) {
      if (await f.exists()) await f.delete();
    } else {
      await f.writeAsString(jsonEncode({'id': w.id, 'name': w.name}));
    }
  }
}

enum _Section { dashboard, work }

/// The app after sign-in: the IMS mobile view (drawer with the user and warehouse;
/// Dashboard, Work, Quick Relocation) plus Scan Pull and History.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.session, required this.onSignedOut});

  final BrijjSession session;
  final Future<void> Function() onSignedOut;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffold = GlobalKey<ScaffoldState>();
  _Section _section = _Section.dashboard;
  List<Warehouse> _warehouses = [];
  Warehouse? _warehouse;
  String? _error;

  // Work + dashboard data for the selected warehouse.
  List<WorkItem>? _work;
  WorkFilter _filter = WorkFilter.all;
  int _approvals = 0;
  int _toReceive = 0;
  int _awaiting = 0;
  int _unsubmitted = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final saved = await WarehouseStore.load();
    if (saved != null && mounted) setState(() => _warehouse = saved);
    final api = TpmApi(widget.session.env);
    try {
      _warehouses = await api.activeWarehouses(widget.session);
      if (_warehouse == null || !_warehouses.any((w) => w.id == _warehouse!.id)) {
        final def = await api.defaultWarehouseId(widget.session);
        _warehouse = _warehouses.where((w) => w.id == def).firstOrNull ?? _warehouses.firstOrNull;
      }
    } on TpmApiException catch (e) {
      // Offline: keep the remembered warehouse; Work/Dashboard say they need a connection.
      _error = e is OfflineException ? null : e.message;
    } finally {
      api.close();
    }
    if (!mounted) return;
    setState(() {});
    await _refresh();
  }

  Future<void> _refresh() async {
    final wh = _warehouse;
    _unsubmitted = await ScanStore.savedCount();
    _awaiting = (await PendingMoveStore.load()).length;
    if (wh == null) {
      if (mounted) setState(() {});
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = TpmApi(widget.session.env);
    try {
      final work = flattenWork(await api.myWorklists(widget.session, wh.id));
      final approvals = await api.pendingApprovals(widget.session, wh.id);
      final toReceive = (await api.readyToReceive(widget.session, wh.id)).length;
      if (_awaiting > 0) await PendingMoveStore.checkAll(api, widget.session);
      _awaiting = (await PendingMoveStore.load()).length;
      if (mounted) {
        setState(() {
          _work = work;
          _approvals = approvals;
          _toReceive = toReceive;
        });
      }
    } on TpmApiException catch (e) {
      if (mounted) setState(() => _error = e is OfflineException ? 'Offline — work and dashboard need a connection.' : e.message);
    } finally {
      api.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _switchWarehouse() async {
    _scaffold.currentState?.closeDrawer();
    if (_warehouses.isEmpty) return;
    final picked = await showDialog<Warehouse>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Switch warehouse'),
        children: [
          for (final w in _warehouses)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, w),
              child: Row(
                children: [
                  Icon(w.id == _warehouse?.id ? Icons.radio_button_checked : Icons.radio_button_off, color: brijjBlue),
                  const SizedBox(width: 12),
                  Text(w.name, style: const TextStyle(fontSize: 16)),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked.id == _warehouse?.id) return;
    await WarehouseStore.save(picked);
    setState(() {
      _warehouse = picked;
      _work = null;
    });
    _refresh();
  }

  Future<void> _push(Widget page) async {
    _scaffold.currentState?.closeDrawer();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    _refresh();
  }

  /// Signing out from any screen returns here first, then to sign-in.
  Future<void> _signedOut() async {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await widget.onSignedOut();
  }

  void _openScanPull() => _push(ScanListPage(session: widget.session, onSignedOut: _signedOut, warehouseId: _warehouse?.id));

  void _openQuickRelocation() {
    final wh = _warehouse;
    if (wh != null) _push(QuickRelocationPage(session: widget.session, warehouse: wh));
  }

  Future<void> _openHistory() async {
    // The Scan Pull screen saves its destination; prefer the selected warehouse.
    final cache = LookupCache();
    await cache.load();
    final wh = _warehouse;
    _push(HistoryPage(session: widget.session, warehouseId: wh?.id ?? cache.destination?.warehouseId, warehouseName: wh?.name));
  }

  void _openQuickTransfer() {
    final wh = _warehouse;
    if (wh == null) return;
    if (_warehouses.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Quick Transfer needs another active warehouse.')));
      return;
    }
    _push(QuickTransferPage(session: widget.session, from: wh, warehouses: _warehouses));
  }

  void _openQuickReceive() {
    final wh = _warehouse;
    if (wh != null) _push(QuickReceiveListPage(session: widget.session, warehouse: wh));
  }

  void _openLicensePlates() {
    final wh = _warehouse;
    if (wh != null) _push(LicensePlatesPage(session: widget.session, warehouse: wh));
  }

  void _openAwaiting() => _push(PendingMovesPage(session: widget.session, onReAdd: ScanStore.appendSaved));

  void _openWork(WorkItem item) {
    switch (item.handler) {
      case WorkHandler.count:
        _push(CountPage(session: widget.session, worklistId: item.worklistId, warehouseId: _warehouse?.id ?? 0));
      case WorkHandler.relocation:
        _push(RelocationTaskPage(session: widget.session, worklistId: item.worklistId));
      case WorkHandler.imsPage:
        _push(ImsWebPage(session: widget.session, path: item.imsPath, title: '${item.actionLabel} · ${item.typeRef}', warehouseId: _warehouse?.id));
    }
  }

  Future<void> _logout() async {
    _scaffold.currentState?.closeDrawer();
    final version = await Updater.currentVersion();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.session.fullName),
        content: Text(
          '${widget.session.companyLabel}\nApp version $version'
          '${_unsubmitted == 0 ? '' : '\n\nLogging out clears the $_unsubmitted unsubmitted Scan Pull barcode(s) on this device.'}'
          '${_awaiting == 0 ? '' : '\n\n$_awaiting pull(s) still awaiting IMS confirmation will no longer be tracked here — check them in IMS.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Logout')),
        ],
      ),
    );
    if (ok != true) return;
    // The next person on this device must not submit this user's list under their own name.
    await ScanStore.deleteSaved();
    await LookupCache.clear();
    await PendingMoveStore.clear();
    final api = TpmApi(widget.session.env);
    await api.signOut(widget.session);
    api.close();
    await widget.onSignedOut();
  }

  // ── Drawer (IMS mobile menu) ───────────────────────────────────────────────

  Widget _drawer() {
    Widget item(IconData icon, String title, VoidCallback onTap, {bool active = false, Color? color}) => ListTile(
      leading: Icon(icon, color: color ?? (active ? brijjBlue : null)),
      title: Text(title, style: TextStyle(fontSize: 17, color: color, fontWeight: active ? FontWeight.w600 : null)),
      selected: active,
      selectedTileColor: brijjBlueTint,
      onTap: onTap,
    );
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Align(alignment: Alignment.centerLeft, child: Image.asset('assets/brijj_logo.png', height: 32)),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              child: ListTile(
                leading: UserAvatar(name: widget.session.fullName, radius: 24),
                title: Text(widget.session.fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Warehouse: '),
                      TextSpan(
                        text: _warehouse?.name ?? '—',
                        style: const TextStyle(color: brijjGreen, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                trailing: _warehouses.length > 1 ? const Icon(Icons.swap_horiz) : null,
                onTap: _warehouses.length > 1 ? _switchWarehouse : null,
              ),
            ),
            const SizedBox(height: 12),
            item(Icons.dashboard, 'Dashboard', () {
              _scaffold.currentState?.closeDrawer();
              setState(() => _section = _Section.dashboard);
            }, active: _section == _Section.dashboard),
            item(Icons.show_chart, 'Work', () {
              _scaffold.currentState?.closeDrawer();
              setState(() => _section = _Section.work);
            }, active: _section == _Section.work),
            item(Icons.move_down, 'Quick Relocation', _openQuickRelocation),
            item(Icons.local_shipping, 'Quick Transfer', _openQuickTransfer),
            item(Icons.move_to_inbox, 'Quick Receive', _openQuickReceive),
            item(Icons.pallet, 'License Plates', _openLicensePlates),
            item(Icons.remove_shopping_cart, 'Scan Pull', _openScanPull),
            item(Icons.history, 'History', _openHistory),
            const Divider(),
            item(Icons.logout, 'Logout', _logout, color: statusDanger),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffold,
      drawer: _drawer(),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_section == _Section.dashboard ? 'Dashboard' : 'Work'),
            Text(_warehouse?.name ?? '', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh))],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _section == _Section.dashboard ? _dashboard() : _workList(),
      ),
    );
  }

  // ── Dashboard ──────────────────────────────────────────────────────────────

  Widget _stat(String label, String value, IconData icon, {VoidCallback? onTap, Color? color}) => Expanded(
    child: Card(
      margin: const EdgeInsets.all(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color ?? brijjBlue),
              const SizedBox(height: 6),
              Text(value, style: const TextStyle(fontFamily: headingFont, fontSize: 28, fontWeight: FontWeight.w600)),
              Text(label, style: const TextStyle(color: brijjText)),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _dashboard() {
    final me = widget.session.userId;
    final work = _work ?? const <WorkItem>[];
    final mineActive = work.where((w) => w.isMine(me) && w.inProgress).toList();
    final ongoing = mineActive.firstOrNull;
    String n(int v) => _work == null ? '–' : '$v';
    void showWork(WorkFilter f) => setState(() {
      _filter = f;
      _section = _Section.work;
    });
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const UpdateCard(),
        Text('Welcome back, ${widget.session.fullName.split(' ').first}', style: const TextStyle(fontSize: 18)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: statusWarning, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            _stat('My tasks', n(work.where((w) => w.isMine(me)).length), Icons.person, onTap: () => showWork(WorkFilter.mine)),
            _stat('Open tasks', n(work.length), Icons.assignment, onTap: () => showWork(WorkFilter.all)),
          ],
        ),
        Row(
          children: [
            _stat('Unassigned', n(work.where((w) => w.isUnassigned).length), Icons.assignment_late, onTap: () => showWork(WorkFilter.unassigned)),
            _stat(
              'Counts to approve',
              n(_approvals),
              Icons.fact_check,
              onTap: () => _push(ImsWebPage(session: widget.session, path: '/counting/counting-approval', title: 'Counting Approval', warehouseId: _warehouse?.id)),
            ),
          ],
        ),
        Row(
          children: [
            _stat('Ready to receive', n(_toReceive), Icons.move_to_inbox, onTap: _openQuickReceive),
            _stat('License plates', '›', Icons.pallet, onTap: _openLicensePlates),
          ],
        ),
        if (ongoing != null)
          Card(
            color: brijjBlueTint,
            child: ListTile(
              leading: const Icon(Icons.play_circle, color: brijjBlue, size: 36),
              title: Text('Ongoing: ${ongoing.taskName}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${ongoing.typeRef} · ${ongoing.ref}'),
              trailing: FilledButton(onPressed: () => _openWork(ongoing), child: const Text('Resume')),
            ),
          ),
        if (_awaiting > 0 || _unsubmitted > 0)
          Card(
            color: statusWarningTint,
            child: Column(
              children: [
                if (_awaiting > 0)
                  ListTile(
                    leading: const Icon(Icons.hourglass_top, color: statusWarning),
                    title: Text('$_awaiting pull(s) awaiting IMS confirmation'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _openAwaiting,
                  ),
                if (_unsubmitted > 0)
                  ListTile(
                    leading: const Icon(Icons.remove_shopping_cart, color: statusWarning),
                    title: Text('$_unsubmitted scanned barcode(s) not submitted yet'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _openScanPull,
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        const Text('Quick actions', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(onPressed: _openScanPull, icon: const Icon(Icons.remove_shopping_cart), label: const Text('Scan Pull')),
            FilledButton.tonalIcon(onPressed: _openQuickRelocation, icon: const Icon(Icons.move_down), label: const Text('Quick Relocation')),
            FilledButton.tonalIcon(onPressed: _openQuickTransfer, icon: const Icon(Icons.local_shipping), label: const Text('Quick Transfer')),
            FilledButton.tonalIcon(onPressed: _openQuickReceive, icon: const Icon(Icons.move_to_inbox), label: const Text('Quick Receive')),
            OutlinedButton.icon(onPressed: () => showWork(WorkFilter.all), icon: const Icon(Icons.show_chart), label: const Text('Work')),
            OutlinedButton.icon(onPressed: _openHistory, icon: const Icon(Icons.history), label: const Text('History')),
          ],
        ),
      ],
    );
  }

  // ── Work (IMS work items) ──────────────────────────────────────────────────

  Widget _workList() {
    final work = _work;
    final shown = work == null ? const <WorkItem>[] : filterWork(work, _filter, widget.session.userId);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            children: [
              for (final f in WorkFilter.values)
                ChoiceChip(
                  label: Text(switch (f) {
                    WorkFilter.all => 'All',
                    WorkFilter.mine => 'Mine',
                    WorkFilter.unassigned => 'Unassigned',
                  }),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
            ],
          ),
        ),
        if (_error != null)
          ListTile(leading: const Icon(Icons.cloud_off, color: statusWarning), title: Text(_error!)),
        if (work == null && _error == null)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
        if (work != null && shown.isEmpty)
          const ListTile(leading: Icon(Icons.inbox), title: Text('No work here'), subtitle: Text('Pull down to refresh.')),
        for (final w in shown) _workCard(w),
      ],
    );
  }

  Widget _workCard(WorkItem w) {
    String when(DateTime t) => '${t.month}/${t.day}/${t.year % 100}';
    final native = w.handler != WorkHandler.imsPage;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    w.typeRef.isEmpty ? w.ref : w.typeRef,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(w.typeName, style: const TextStyle(color: brijjText)),
              ],
            ),
            Text(
              [
                w.ref,
                'created ${when(w.createdAt)}',
                if (w.productCount > 0) '${w.productCount} item(s)',
              ].join(' · '),
            ),
            Text(
              w.isMine(widget.session.userId) ? 'Assigned to you' : (w.assignee.isEmpty ? 'Unassigned' : 'Assigned to ${w.assignee}'),
              style: const TextStyle(color: brijjText),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(onPressed: () => _openWork(w), child: Text(w.actionLabel)),
                const SizedBox(width: 8),
                if (!native) const Text('opens in IMS', style: TextStyle(color: brijjText, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
