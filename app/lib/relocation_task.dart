import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'count_model.dart' show shortProductName;
import 'relocation_model.dart';
import 'scan_input.dart';
import 'tpm_api.dart';

/// A Relocation work item (movement order task), done natively the way the IMS
/// mobile view does it: Start → for each line pick it, set its destination, mark it
/// relocated → Finish.
class RelocationTaskPage extends StatefulWidget {
  const RelocationTaskPage({super.key, required this.session, required this.worklistId});

  final BrijjSession session;
  final int worklistId;

  @override
  State<RelocationTaskPage> createState() => _RelocationTaskPageState();
}

class _RelocationTaskPageState extends State<RelocationTaskPage> {
  final _scanKey = GlobalKey<ScanInputState>();
  Map<String, dynamic>? _worklist;
  Map<String, dynamic>? _order;
  List<RelocationLine> _lines = [];
  String? _error;
  bool _loading = true;
  bool _busy = false;
  String? _flash;
  Color _flashColor = statusSuccess;

  /// The line being worked: the first one not relocated yet.
  RelocationLine? get _current => _lines.where((l) => l.status != LineStatus.relocated && l.status != LineStatus.cancelled).firstOrNull;

  int get _warehouseId => ((_worklist?['warehouseId'] ?? _order?['warehouseId']) as num?)?.toInt() ?? 0;

  Map<String, dynamic>? get _task {
    final lines = ((_worklist?['worklistLineItems'] as List?) ?? const []).cast<Map>();
    return (lines.where((l) => l['type'] == 9).firstOrNull ?? lines.firstOrNull)?.cast<String, dynamic>();
  }

  bool get _started => _task != null && _task!['status'] == 3 && '${_task!['userId']}' == widget.session.userId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _say(String message, Color color) => setState(() {
    _flash = message;
    _flashColor = color;
  });

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = TpmApi(widget.session.env);
    try {
      final wl = await api.worklist(widget.session, widget.worklistId);
      _worklist = wl;
      final orderId = (_task?['referenceId'] as num?)?.toInt();
      if (orderId == null) throw TpmApiException('This work item has no movement order.');
      final order = await api.movementOrderRaw(widget.session, orderId);
      if (order['status'] == OrderStatus.cancelled) throw TpmApiException('This work has been cancelled.');
      setState(() {
        _order = order;
        _lines = relocationLines(order);
      });
    } on TpmApiException catch (e) {
      _error = e is OfflineException ? 'Offline — the task needs a connection to load.' : e.message;
    } finally {
      api.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  /// IMS "Start": work item In progress for this user, movement order Work in progress.
  Future<void> _start() async {
    setState(() => _busy = true);
    final api = TpmApi(widget.session.env);
    try {
      final me = int.tryParse(widget.session.userId) ?? widget.session.userId;
      final lines = (_worklist!['worklistLineItems'] as List).cast<Map>();
      lines.first['status'] = 3;
      lines.first['userId'] = me;
      await api.updateWorklist(widget.session, _worklist!);
      if (_order!['status'] != OrderStatus.processing) {
        await api.changeMovementOrderStatus(widget.session, (_order!['id'] as num).toInt(), OrderStatus.workInProgress);
      }
      _worklist = await api.worklist(widget.session, widget.worklistId);
      _task?['status'] = 3;
      _task?['userId'] = me;
    } on TpmApiException catch (e) {
      _say(e.message, statusDanger);
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _picked(RelocationLine l) {
    setState(() => l.status = LineStatus.picked);
    HapticFeedback.lightImpact();
    _say('Picked — now scan or choose the destination', statusSuccess);
  }

  void _relocated(RelocationLine l) {
    if (l.destinationId == null) {
      _say('Set a destination first', statusWarning);
      return;
    }
    setState(() => l.status = LineStatus.relocated);
    HapticFeedback.mediumImpact();
    _say(_current == null ? 'All lines relocated — tap Finish' : 'Relocated — next line', statusSuccess);
  }

  Future<void> _onScan(String barcode) async {
    final l = _current;
    if (!_started || l == null || _busy) return;
    if (l.status == LineStatus.pending) {
      if (l.serials.contains(barcode) || l.sku == barcode) {
        _picked(l);
      } else {
        HapticFeedback.heavyImpact();
        final other = _lines.where((x) => x != l && x.serials.contains(barcode)).firstOrNull;
        _say(other == null ? '$barcode isn\'t on this line' : '$barcode belongs to another line (${shortProductName(other.product)})', statusWarning);
      }
      return;
    }
    // Picked: a scan is the destination location's label.
    setState(() => _busy = true);
    final api = TpmApi(widget.session.env);
    try {
      final loc = await api.scanLocation(widget.session, barcode, _warehouseId);
      final problem = l.setDestination((loc['id'] as num).toInt(), '${loc['name'] ?? barcode}');
      if (problem != null) {
        HapticFeedback.heavyImpact();
        _say(problem, statusDanger);
      } else {
        HapticFeedback.lightImpact();
        _say('Destination: ${l.destination}', statusSuccess);
      }
    } on TpmApiException catch (e) {
      HapticFeedback.heavyImpact();
      _say(e is OfflineException ? 'Offline — can\'t check that location' : '"$barcode" isn\'t a location here', statusDanger);
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseDestination(RelocationLine l) async {
    final api = TpmApi(widget.session.env);
    List<Map<String, dynamic>> locations;
    try {
      locations = await api.warehouseLocations(widget.session, _warehouseId);
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
              const ListTile(title: Text('Destination', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
              for (final loc in locations)
                if (loc['id'] != l.sourceId)
                  ListTile(
                    leading: const Icon(Icons.place),
                    title: Text('${loc['name']}'),
                    subtitle: Text('${(loc['warehouseLocationProfile'] as Map?)?['name'] ?? ''}'),
                    onTap: () => Navigator.pop(context, loc),
                  ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final problem = l.setDestination((picked['id'] as num).toInt(), '${picked['name']}');
    _say(problem ?? 'Destination: ${l.destination}', problem == null ? statusSuccess : statusDanger);
    _scanKey.currentState?.refocus();
  }

  Future<void> _finish() async {
    final done = _lines.where((l) => l.status == LineStatus.relocated).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finish relocation?'),
        content: Text(
          '$done of ${_lines.length} line(s) relocated.'
          '${done < _lines.length ? '\n\nThe rest stay open on ${_order?['referenceNumber']} for later.' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep working')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Finish')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final api = TpmApi(widget.session.env);
    try {
      finishRelocation(_order!, _worklist!, _warehouseId);
      final saved = await api.updateMovementOrder(widget.session, _order!);
      await api.updateWorklist(widget.session, _worklist!);
      if (!mounted) return;
      final ref = _order?['referenceNumber'];
      final queued = saved['status'] == OrderStatus.queued;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Relocation saved'),
          content: Text(
            done == _lines.length
                ? (queued ? '$ref is queued for processing in IMS.' : '$ref is completed.')
                : '$done of ${_lines.length} line(s) relocated on $ref; the rest stay open.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on TpmApiException catch (e) {
      _say(e is OfflineException ? 'Offline — finish again when connected' : e.message, statusDanger);
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final current = _current;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${order?['referenceNumber'] ?? 'Relocation'}'),
            if (order != null)
              Text('${order['reason'] ?? ''}'.trim().isEmpty ? 'Relocation' : '${order['reason']}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      bottomNavigationBar: order == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  onPressed: _busy ? null : (_started ? _finish : _start),
                  icon: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(_started ? Icons.check : Icons.play_arrow),
                  label: Text(_started ? 'Finish relocation' : 'Start relocation', style: const TextStyle(fontSize: 18)),
                ),
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.error, color: statusDanger),
                  title: Text(_error!),
                  trailing: TextButton(onPressed: _load, child: const Text('Retry')),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                ScanInput(
                  key: _scanKey,
                  onScan: _onScan,
                  enabled: _started && current != null,
                  label: !_started
                      ? 'Tap Start relocation to begin'
                      : current == null
                      ? 'All lines relocated'
                      : current.status == LineStatus.pending
                      ? 'Scan the item to pick it'
                      : 'Scan the destination location',
                ),
                if (_flash != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_flash!, style: TextStyle(color: _flashColor, fontWeight: FontWeight.w600)),
                  ),
                if (current != null && _started) _currentCard(current),
                const SizedBox(height: 12),
                Text(
                  'Lines (${_lines.where((l) => l.status == LineStatus.relocated).length} of ${_lines.length} relocated)',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                for (final l in _lines) _lineTile(l),
              ],
            ),
    );
  }

  Widget _currentCard(RelocationLine l) {
    final picked = l.status == LineStatus.picked;
    return Card(
      color: brijjBlueTint,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(picked ? 'Relocating' : 'Picking', style: const TextStyle(color: brijjBlue, fontWeight: FontWeight.w700)),
            Text(
              l.licensePlate ?? (l.product.isEmpty ? '${l.quantity} item(s)' : shortProductName(l.product)),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            Text('${l.sku.isEmpty ? '' : '${l.sku} · '}Qty ${l.quantity} · from ${l.source}'),
            if (l.serials.isNotEmpty)
              Text(
                l.serials.take(10).join('  ') + (l.serials.length > 10 ? '  … +${l.serials.length - 10}' : ''),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            const SizedBox(height: 8),
            if (!picked)
              FilledButton.tonal(onPressed: () => _picked(l), child: const Text('Mark picked'))
            else ...[
              Text(l.destination.isEmpty ? 'Destination: not set' : 'Destination: ${l.destination}', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(onPressed: () => _chooseDestination(l), child: const Text('Choose location')),
                  FilledButton(onPressed: l.destinationId == null ? null : () => _relocated(l), child: const Text('Relocated')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _lineTile(RelocationLine l) {
    final (icon, color, label) = switch (l.status) {
      LineStatus.relocated => (Icons.check_circle, statusSuccess, 'Relocated'),
      LineStatus.picked => (Icons.shopping_basket, brijjBlue, 'Picked'),
      LineStatus.cancelled => (Icons.cancel, statusDanger, 'Cancelled'),
      _ => (Icons.radio_button_unchecked, brijjText, 'Pending'),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(l.licensePlate ?? (l.product.isEmpty ? '${l.quantity} item(s)' : shortProductName(l.product))),
      subtitle: Text('${l.source} → ${l.destination.isEmpty ? '?' : l.destination} · Qty ${l.quantity}'),
      trailing: Text(label, style: TextStyle(color: color)),
    );
  }
}
