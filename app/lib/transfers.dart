import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'count_model.dart' show shortProductName;
import 'scan_input.dart';
import 'tpm_api.dart';
import 'transfer_model.dart';

String _name(String product) => product.isEmpty ? 'Item' : shortProductName(product);

/// Quick Transfer, as in the IMS web app: from this warehouse to another, by
/// scanned items or by license plate, created and processed in one step.
class QuickTransferPage extends StatefulWidget {
  const QuickTransferPage({super.key, required this.session, required this.from, required this.warehouses});

  final BrijjSession session;
  final Warehouse from;
  final List<Warehouse> warehouses;

  @override
  State<QuickTransferPage> createState() => _QuickTransferPageState();
}

class _QuickTransferPageState extends State<QuickTransferPage> {
  final _scanKey = GlobalKey<ScanInputState>();
  final _notes = TextEditingController();
  Warehouse? _to;
  int _scope = TransferScope.product;
  int _priority = 2;
  final _products = <int, TransferProduct>{};
  final _plates = <int, Map<String, dynamic>>{};
  List<Map<String, dynamic>>? _warehousePlates;
  bool _busy = false;
  String? _flash;
  Color _flashColor = statusSuccess;

  List<Warehouse> get _destinations => [for (final w in widget.warehouses) if (w.id != widget.from.id) w];

  int get _count => _scope == TransferScope.product ? _products.values.fold(0, (t, p) => t + p.quantity) : _plates.length;

  @override
  void initState() {
    super.initState();
    if (_destinations.length == 1) _to = _destinations.first;
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  void _say(String m, Color c) => setState(() {
    _flash = m;
    _flashColor = c;
  });

  Future<void> _loadPlates() async {
    if (_warehousePlates != null) return;
    final api = TpmApi(widget.session.env);
    try {
      final plates = await api.licensePlates(widget.session, widget.from.id);
      if (mounted) setState(() => _warehousePlates = plates);
    } on TpmApiException catch (e) {
      _say(e.message, statusDanger);
    } finally {
      api.close();
    }
  }

  void _addPlate(Map<String, dynamic> lp) {
    final id = (lp['id'] as num).toInt();
    if (_plates.containsKey(id)) {
      HapticFeedback.heavyImpact();
      _say('${lp['referenceNumber']} is already added', statusWarning);
      return;
    }
    setState(() => _plates[id] = lp);
    HapticFeedback.lightImpact();
    _say('Added ${lp['referenceNumber']}', statusSuccess);
  }

  Future<void> _onScan(String barcode) async {
    if (_busy) return;
    if (_scope == TransferScope.licensePlate) {
      await _loadPlates();
      final lp = _warehousePlates?.where((p) => '${p['referenceNumber']}'.toUpperCase() == barcode.toUpperCase()).firstOrNull;
      if (lp == null) {
        HapticFeedback.heavyImpact();
        _say('$barcode isn\'t a license plate in ${widget.from.name}', statusDanger);
      } else {
        _addPlate(lp);
      }
      return;
    }
    if (_products.values.any((p) => p.serials.containsValue(barcode))) {
      HapticFeedback.heavyImpact();
      _say('$barcode is already added', statusWarning);
      return;
    }
    final api = TpmApi(widget.session.env);
    try {
      final serial = (await api.imsFind(widget.session, barcode, [widget.from.id])).firstOrNull;
      if (serial == null) {
        HapticFeedback.heavyImpact();
        _say('$barcode isn\'t in ${widget.from.name} inventory', statusDanger);
        return;
      }
      final (ok, message) = await api.validateSerialUsage(widget.session, serial.serialId, widget.from.id);
      if (!ok) {
        HapticFeedback.heavyImpact();
        _say(message.isEmpty ? '$barcode can\'t be transferred' : message, statusDanger);
        return;
      }
      setState(() {
        _products.putIfAbsent(serial.productId, () => TransferProduct(serial.productId, serial.productName)).serials[serial.serialId] = barcode;
      });
      HapticFeedback.lightImpact();
      _say(message.isEmpty ? 'Added $barcode' : 'Added $barcode — $message', message.isEmpty ? statusSuccess : statusWarning);
    } on TpmApiException catch (e) {
      HapticFeedback.heavyImpact();
      _say(e is OfflineException ? 'Offline — Quick Transfer needs a connection' : e.message, statusDanger);
    } finally {
      api.close();
    }
  }

  Future<void> _choosePlate() async {
    await _loadPlates();
    if (!mounted || _warehousePlates == null) return;
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: ListView(
            children: [
              ListTile(title: Text('License plates — ${widget.from.name}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
              for (final lp in _warehousePlates!)
                ListTile(
                  leading: const Icon(Icons.pallet),
                  title: Text('${lp['referenceNumber']}'),
                  subtitle: Text(
                    '${lp['description'] ?? ''} · ${(lp['warehouseLocation'] as Map?)?['name'] ?? ''} · '
                    '${(lp['items'] as List? ?? const []).length} product(s)',
                  ),
                  onTap: () => Navigator.pop(context, lp),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) _addPlate(picked);
    _scanKey.currentState?.refocus();
  }

  Future<void> _submit() async {
    final to = _to;
    if (to == null || _count == 0) return;
    final products = _products.values.toList();
    if (_scope == TransferScope.product && overQuickLimit(products)) {
      _say('Quick Transfer is limited to $quickLimit items — use a regular transfer in IMS', statusDanger);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.session.env == BrijjEnv.production ? 'Quick Transfer — PRODUCTION?' : 'Quick Transfer?'),
        content: Text(
          '${_scope == TransferScope.product ? '$_count item(s)' : '$_count license plate(s)'} from ${widget.from.name} to ${to.name}, '
          'recorded as ${widget.session.fullName}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Transfer')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final api = TpmApi(widget.session.env);
    try {
      final order = await api.createTransferOrder(
        widget.session,
        quickTransferOrder(
          fromWarehouseId: widget.from.id,
          toWarehouseId: to.id,
          scope: _scope,
          companyId: int.tryParse(widget.session.companyId) ?? widget.session.companyId,
          date: DateTime.now(),
          priority: _priority,
          notes: _notes.text.trim(),
          products: products,
          licensePlateIds: _plates.keys.toList(),
        ),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Transfer created'),
          content: Text(
            '${order['referenceNumber'] ?? 'The transfer order'} — ${widget.from.name} → ${to.name}.'
            '\nIt shows as Ready for receive in ${to.name}.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on TpmApiException catch (e) {
      _say(e is OfflineException ? 'Offline — nothing was sent' : e.message, statusDanger);
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _to != null && _count > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Quick Transfer')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: _busy || !ready ? null : _submit,
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.local_shipping),
            label: Text('Transfer $_count ${_scope == TransferScope.product ? 'item(s)' : 'plate(s)'}', style: const TextStyle(fontSize: 18)),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            color: brijjBlueTint,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('From ${widget.from.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<int>(
                    initialValue: _to?.id,
                    decoration: const InputDecoration(labelText: 'To warehouse', border: OutlineInputBorder()),
                    items: [for (final w in _destinations) DropdownMenuItem(value: w.id, child: Text(w.name))],
                    onChanged: (id) => setState(() => _to = _destinations.firstWhere((w) => w.id == id)),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: TransferScope.product, label: Text('Items'), icon: Icon(Icons.qr_code)),
                      ButtonSegment(value: TransferScope.licensePlate, label: Text('License plates'), icon: Icon(Icons.pallet)),
                    ],
                    selected: {_scope},
                    onSelectionChanged: _count > 0
                        ? null
                        : (s) {
                            setState(() => _scope = s.first);
                            if (_scope == TransferScope.licensePlate) _loadPlates();
                          },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ScanInput(
                  key: _scanKey,
                  onScan: _onScan,
                  label: _scope == TransferScope.product ? 'Scan items to transfer' : 'Scan a license plate',
                ),
              ),
              if (_scope == TransferScope.licensePlate)
                IconButton(tooltip: 'Choose a plate', onPressed: _choosePlate, icon: const Icon(Icons.list)),
            ],
          ),
          if (_flash != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_flash!, style: TextStyle(color: _flashColor, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Priority'),
              const SizedBox(width: 12),
              for (final (v, l) in const [(1, 'Low'), (2, 'Medium'), (3, 'High')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text(l), selected: _priority == v, onSelected: (_) => setState(() => _priority = v)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          if (_scope == TransferScope.product)
            for (final p in _products.values)
              Card(
                child: ListTile(
                  title: Text(_name(p.name)),
                  subtitle: Text(p.serials.values.join('  '), style: const TextStyle(fontFamily: 'monospace')),
                  trailing: Text('× ${p.quantity}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  onLongPress: () => setState(() => _products.remove(p.productId)),
                ),
              )
          else
            for (final lp in _plates.values)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.pallet),
                  title: Text('${lp['referenceNumber']}'),
                  subtitle: Text('${lp['description'] ?? ''} · ${(lp['warehouseLocation'] as Map?)?['name'] ?? ''}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _plates.remove((lp['id'] as num).toInt())),
                  ),
                ),
              ),
          if (_scope == TransferScope.product && _products.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Long-press a product to remove it.', style: TextStyle(color: brijjText, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

/// Quick Receive, as in the IMS web app: transfers ready to receive in this
/// warehouse; pick one, confirm what arrived, choose where it goes, receive.
class QuickReceiveListPage extends StatefulWidget {
  const QuickReceiveListPage({super.key, required this.session, required this.warehouse});

  final BrijjSession session;
  final Warehouse warehouse;

  @override
  State<QuickReceiveListPage> createState() => _QuickReceiveListPageState();
}

class _QuickReceiveListPageState extends State<QuickReceiveListPage> {
  List<Map<String, dynamic>>? _items;
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
      final items = await api.readyToReceive(widget.session, widget.warehouse.id);
      if (mounted) setState(() => _items = items);
    } on TpmApiException catch (e) {
      if (mounted) setState(() => _error = e is OfflineException ? 'Offline — needs a connection.' : e.message);
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: Text('Quick Receive — ${widget.warehouse.name}')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(8),
          children: [
            if (_error != null)
              ListTile(leading: const Icon(Icons.cloud_off, color: statusWarning), title: Text(_error!)),
            if (items == null && _error == null)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
            if (items != null && items.isEmpty)
              const ListTile(
                leading: Icon(Icons.inbox),
                title: Text('Nothing ready to receive'),
                subtitle: Text('Transfers already being received show under Work.'),
              ),
            for (final w in items ?? const <Map<String, dynamic>>[])
              Card(
                child: ListTile(
                  leading: const Icon(Icons.local_shipping, size: 32),
                  title: Text('${w['typeReferenceNumber'] ?? w['referenceNumber']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${w['referenceNumber']} · ${w['productCount'] ?? 0} item(s)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final done = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(builder: (_) => QuickReceivePage(session: widget.session, warehouse: widget.warehouse, worklist: w)),
                    );
                    if (done == true) _load();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class QuickReceivePage extends StatefulWidget {
  const QuickReceivePage({super.key, required this.session, required this.warehouse, required this.worklist});

  final BrijjSession session;
  final Warehouse warehouse;
  final Map<String, dynamic> worklist;

  @override
  State<QuickReceivePage> createState() => _QuickReceivePageState();
}

class _QuickReceivePageState extends State<QuickReceivePage> {
  final _scanKey = GlobalKey<ScanInputState>();
  Map<String, dynamic>? _dispatch;
  List<ReceiveLine> _lines = [];
  ({int id, String name})? _dest;
  bool _scanningDestination = true;
  bool _busy = false;
  String? _error;
  String? _flash;
  Color _flashColor = statusSuccess;

  bool get _ready => _dest != null && _lines.isNotEmpty && _lines.every((l) => l.ready);

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _say(String m, Color c) => setState(() {
    _flash = m;
    _flashColor = c;
  });

  Future<void> _load() async {
    final api = TpmApi(widget.session.env);
    try {
      final line = ((widget.worklist['worklistLineItems'] as List?) ?? const []).cast<Map>().firstOrNull;
      final id = (line?['referenceId'] as num?)?.toInt();
      if (id == null) throw TpmApiException('This transfer has no dispatch order.');
      final dispatch = await api.transferDispatchOrder(widget.session, id);
      if (mounted) {
        setState(() {
          _dispatch = dispatch;
          _lines = receiveLines(dispatch);
        });
      }
    } on TpmApiException catch (e) {
      if (mounted) setState(() => _error = e is OfflineException ? 'Offline — needs a connection.' : e.message);
    } finally {
      api.close();
    }
  }

  Future<void> _onScan(String barcode) async {
    if (_busy || _dispatch == null) return;
    if (_scanningDestination) {
      final api = TpmApi(widget.session.env);
      try {
        final loc = await api.scanLocation(widget.session, barcode, widget.warehouse.id);
        setState(() {
          _dest = (id: (loc['id'] as num).toInt(), name: '${loc['name'] ?? barcode}');
          _scanningDestination = false;
        });
        HapticFeedback.lightImpact();
        _say('Destination: ${_dest!.name} — now scan what arrived', statusSuccess);
      } on TpmApiException {
        HapticFeedback.heavyImpact();
        _say('"$barcode" isn\'t a location in ${widget.warehouse.name}', statusDanger);
      } finally {
        api.close();
      }
      return;
    }
    final line = _lines.where((l) => l.dispatched.containsKey(barcode)).firstOrNull;
    if (line == null) {
      HapticFeedback.heavyImpact();
      _say('$barcode isn\'t on this transfer', statusDanger);
    } else if (!line.received.add(barcode)) {
      HapticFeedback.heavyImpact();
      _say('$barcode already received', statusWarning);
    } else {
      HapticFeedback.lightImpact();
      setState(() {});
      _say('Received $barcode · ${_name(line.product)}', statusSuccess);
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
              const ListTile(title: Text('Receive into', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
              for (final l in locations)
                ListTile(leading: const Icon(Icons.place), title: Text('${l['name']}'), onTap: () => Navigator.pop(context, l)),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _dest = (id: (picked['id'] as num).toInt(), name: '${picked['name']}');
        _scanningDestination = false;
      });
    }
    _scanKey.currentState?.refocus();
  }

  Future<void> _receive() async {
    final dest = _dest;
    final dispatch = _dispatch;
    if (dest == null || dispatch == null || !_ready) return;
    final units = _lines.fold<int>(0, (t, l) => t + l.quantity);
    if (units >= quickLimit) {
      _say('Quick Receive is limited to under $quickLimit items — receive it in IMS', statusDanger);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.session.env == BrijjEnv.production ? 'Receive — PRODUCTION?' : 'Receive transfer?'),
        content: Text('${dispatch['referenceNumber']} into ${dest.name} (${widget.warehouse.name}), received by ${widget.session.fullName}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Receive')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final api = TpmApi(widget.session.env);
    try {
      final res = await api.createTransferReceiveOrder(
        widget.session,
        quickReceiveOrder(
          dispatch: dispatch,
          lines: _lines,
          destinationId: dest.id,
          warehouseId: widget.warehouse.id,
          companyId: int.tryParse(widget.session.companyId) ?? widget.session.companyId,
          userId: int.tryParse(widget.session.userId) ?? widget.session.userId,
          date: DateTime.now(),
        ),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Received'),
          content: Text('${res['message'] ?? '${dispatch['referenceNumber']} received into ${dest.name}.'}'),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on TpmApiException catch (e) {
      _say(e is OfflineException ? 'Offline — nothing was sent' : e.message, statusDanger);
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _dispatch;
    final dest = _dest;
    return Scaffold(
      appBar: AppBar(title: Text('${d?['referenceNumber'] ?? widget.worklist['typeReferenceNumber'] ?? 'Receive'}')),
      bottomNavigationBar: d == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  onPressed: _busy || !_ready ? null : _receive,
                  icon: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.move_to_inbox),
                  label: const Text('Receive', style: TextStyle(fontSize: 18)),
                ),
              ),
            ),
      body: _error != null
          ? ListView(children: [ListTile(leading: const Icon(Icons.error, color: statusDanger), title: Text(_error!))])
          : d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text(
                  '${(d['fromWarehouse'] as Map?)?['name'] ?? '?'} → ${(d['toWarehouse'] as Map?)?['name'] ?? widget.warehouse.name}'
                  ' · ${d['transferOrderReference'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Card(
                  color: brijjBlueTint,
                  child: ListTile(
                    leading: const Icon(Icons.place, color: brijjBlue),
                    title: Text(dest == null ? 'Receive into: not set' : 'Receive into: ${dest.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    trailing: Wrap(
                      children: [
                        IconButton(
                          tooltip: 'Scan the location label',
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
                  label: _scanningDestination ? 'Scan the location to receive into' : 'Scan what arrived',
                ),
                if (_flash != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_flash!, style: TextStyle(color: _flashColor, fontWeight: FontWeight.w600)),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_lines.where((l) => l.ready).length} of ${_lines.length} line(s) ready',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        for (final l in _lines) {
                          l.received.addAll(l.dispatched.keys);
                        }
                      }),
                      child: const Text('Mark all arrived'),
                    ),
                  ],
                ),
                for (final l in _lines)
                  Card(
                    child: ListTile(
                      leading: Icon(l.ready ? Icons.check_circle : Icons.radio_button_unchecked, color: l.ready ? statusSuccess : brijjText),
                      title: Text(l.isPlate ? (l.licensePlate ?? 'License plate') : _name(l.product)),
                      subtitle: Text(
                        l.isPlate
                            ? 'Whole plate'
                            : '${l.received.length} of ${l.quantity} received'
                                  '${l.dispatched.length - l.received.length > 0 && l.dispatched.length - l.received.length <= 6 ? '\nStill to scan: ${l.dispatched.keys.where((b) => !l.received.contains(b)).join('  ')}' : ''}',
                      ),
                    ),
                  ),
                if (_lines.any((l) => !l.ready))
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Quick Receive takes the whole transfer. If something didn\'t arrive, receive it in IMS to record the discrepancy.',
                      style: TextStyle(color: brijjText),
                    ),
                  ),
              ],
            ),
    );
  }
}
