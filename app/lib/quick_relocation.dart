import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'pending_moves.dart';
import 'scan_input.dart';
import 'tpm_api.dart';
import 'updater.dart';

/// IMS Quick Relocation on the device: pick a destination location in the
/// warehouse, scan the items, give a reason, submit — one IMS quick movement order
/// (the same request the IMS web Quick Relocation sends for serial barcodes).
class QuickRelocationPage extends StatefulWidget {
  const QuickRelocationPage({super.key, required this.session, required this.warehouse});

  final BrijjSession session;
  final Warehouse warehouse;

  @override
  State<QuickRelocationPage> createState() => _QuickRelocationPageState();
}

class _Item {
  _Item(this.barcode);

  final String barcode;
  ImsSerial? serial;
  String? problem;
  bool checking = true;
}

class _QuickRelocationPageState extends State<QuickRelocationPage> {
  final _scanKey = GlobalKey<ScanInputState>();
  final _reason = TextEditingController();
  final _items = <_Item>[];
  ({int id, String name})? _dest;

  /// The next scan is a location label (the destination), not an item.
  bool _scanningDestination = true;
  bool _busy = false;
  String? _flash;
  Color _flashColor = statusSuccess;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _say(String m, Color c) => setState(() {
    _flash = m;
    _flashColor = c;
  });

  void _setDestination(int id, String name) {
    setState(() {
      _dest = (id: id, name: name);
      _scanningDestination = false;
      for (final i in _items) {
        _judge(i);
      }
    });
    _say('Destination: $name — now scan the items', statusSuccess);
  }

  void _judge(_Item i) {
    if (i.checking) return;
    final s = i.serial;
    i.problem = s == null
        ? 'Not in IMS for ${widget.warehouse.name}'
        : (_dest != null && s.locationId == _dest!.id)
        ? 'Already in ${_dest!.name}'
        : null;
  }

  Future<void> _onScan(String barcode) async {
    if (_busy) return;
    final api = TpmApi(widget.session.env);
    try {
      if (_scanningDestination) {
        final loc = await api.scanLocation(widget.session, barcode, widget.warehouse.id);
        HapticFeedback.lightImpact();
        _setDestination((loc['id'] as num).toInt(), '${loc['name'] ?? barcode}');
        return;
      }
      if (_items.any((i) => i.barcode == barcode)) {
        HapticFeedback.heavyImpact();
        _say('$barcode is already in the list', statusWarning);
        return;
      }
      final item = _Item(barcode);
      setState(() => _items.insert(0, item));
      final found = await api.imsFind(widget.session, barcode, [widget.warehouse.id]);
      item
        ..serial = found.firstOrNull
        ..checking = false;
      _judge(item);
      if (!mounted) return;
      setState(() {});
      if (item.problem != null) {
        HapticFeedback.heavyImpact();
        _say('$barcode — ${item.problem}', statusDanger);
      } else {
        HapticFeedback.lightImpact();
        _say('$barcode — from ${item.serial!.locationName}', statusSuccess);
      }
    } on TpmApiException catch (e) {
      HapticFeedback.heavyImpact();
      _say(
        e is OfflineException
            ? 'Offline — Quick Relocation needs a connection'
            : (_scanningDestination ? '"$barcode" isn\'t a location in ${widget.warehouse.name}' : e.message),
        statusDanger,
      );
      _items.removeWhere((i) => i.barcode == barcode && i.checking);
      if (mounted) setState(() {});
    } finally {
      api.close();
    }
  }

  Future<void> _chooseDestination() async {
    final api = TpmApi(widget.session.env);
    List<Map<String, dynamic>> locations;
    try {
      locations = await api.warehouseLocations(widget.session, widget.warehouse.id);
    } on TpmApiException catch (e) {
      _say(e.message, statusDanger);
      return;
    } finally {
      api.close();
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: ListView(
            children: [
              ListTile(title: Text('Move to — ${widget.warehouse.name}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
              for (final l in locations)
                ListTile(
                  leading: const Icon(Icons.place),
                  title: Text('${l['name']}'),
                  subtitle: Text('${(l['warehouseLocationProfile'] as Map?)?['name'] ?? ''}'),
                  onTap: () => Navigator.pop(context, l),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) _setDestination((picked['id'] as num).toInt(), '${picked['name']}');
    _scanKey.currentState?.refocus();
  }

  Future<void> _submit() async {
    final dest = _dest;
    if (dest == null) return;
    final ready = {for (final i in _items) if (!i.checking && i.problem == null && i.serial != null) i.barcode: i.serial!};
    if (ready.isEmpty) {
      _say('Nothing to move — scan items first', statusWarning);
      return;
    }
    final reason = _reason.text.trim().isEmpty ? 'Quick Relocation' : _reason.text.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.session.env == BrijjEnv.production ? 'Move items — PRODUCTION?' : 'Move items?'),
        content: Text(
          '${ready.length} item(s) will be moved to ${dest.name} (${widget.warehouse.name}), '
          'recorded as ${widget.session.fullName}.\nReason: $reason'
          '${ready.length < _items.length ? '\n\n${_items.length - ready.length} flagged item(s) will be skipped.' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final api = TpmApi(widget.session.env);
    try {
      final version = await Updater.currentVersion();
      final outcome = await api.moveToLocation(
        widget.session,
        ScanPullLocation(
          id: dest.id,
          name: dest.name,
          warehouseId: widget.warehouse.id,
          warehouseName: widget.warehouse.name,
          allWarehouseIds: [widget.warehouse.id],
          salesFloorIds: const [],
        ),
        ready,
        reason: reason,
        instruction: 'Brijj Inventory app v$version',
      );
      await PendingMoveStore.add(outcome.pending);
      final moved = outcome.results.where((r) => r.pulled).length;
      final refs = {for (final r in outcome.results) ?r.note}.join(', ');
      if (!mounted) return;
      setState(() => _items.removeWhere((i) => outcome.results.any((r) => r.barcode == i.barcode && r.pulled)));
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Moved'),
          content: Text(
            '$moved item(s) moved to ${dest.name}.\n$refs'
            '${outcome.pending.isEmpty ? '' : '\n\nIMS is still processing — it shows under Awaiting IMS until confirmed.'}',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        ),
      );
    } on TpmApiException catch (e) {
      _say(e is OfflineException ? 'Offline — nothing was sent' : e.message, statusDanger);
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
    _scanKey.currentState?.refocus();
  }

  @override
  Widget build(BuildContext context) {
    final dest = _dest;
    final ready = _items.where((i) => !i.checking && i.problem == null).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Quick Relocation')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: _busy || dest == null || ready == 0 ? null : _submit,
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.move_down),
            label: Text('Move $ready item(s)', style: const TextStyle(fontSize: 18)),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            color: brijjBlueTint,
            child: ListTile(
              leading: const Icon(Icons.place, color: brijjBlue),
              title: Text(dest == null ? 'Destination: not set' : 'To: ${dest.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(widget.warehouse.name),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    tooltip: 'Scan the destination label',
                    onPressed: () => setState(() => _scanningDestination = true),
                    icon: Icon(Icons.qr_code, color: _scanningDestination ? brijjBlue : null),
                  ),
                  IconButton(tooltip: 'Choose a location', onPressed: _chooseDestination, icon: const Icon(Icons.list)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ScanInput(
            key: _scanKey,
            onScan: _onScan,
            label: _scanningDestination ? 'Scan the destination location' : 'Scan items to move',
          ),
          if (_flash != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_flash!, style: TextStyle(color: _flashColor, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(labelText: 'Reason', hintText: 'Quick Relocation', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          for (final i in _items)
            ListTile(
              dense: true,
              leading: i.checking
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(i.problem == null ? Icons.check_circle : Icons.block, color: i.problem == null ? statusSuccess : statusDanger),
              title: Text(i.barcode, style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
              subtitle: Text(i.checking ? 'Checking IMS…' : (i.problem ?? 'from ${i.serial!.locationName}')),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _items.remove(i)),
              ),
            ),
        ],
      ),
    );
  }
}
