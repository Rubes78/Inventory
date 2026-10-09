import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'count_model.dart' show shortProductName;
import 'scan_input.dart';
import 'tpm_api.dart';

/// LicensePlateStatus (IMS).
String plateStatus(Object? s) => switch (s) {
  1 => 'In use',
  2 => 'Relocating',
  3 => 'Available',
  4 => 'Transfer pending',
  5 => 'In transit',
  _ => 'Unknown',
};

String _when(Object? iso) {
  final t = DateTime.tryParse('$iso')?.toLocal();
  return t == null ? '' : '${t.month}/${t.day}/${t.year % 100}';
}

int _units(Map<String, dynamic> lp) =>
    (lp['items'] as List? ?? const []).fold<int>(0, (t, i) => t + ((i is Map ? i['quantity'] : 0) as num? ?? 0).toInt());

/// License plates in the warehouse: search, or scan a plate label — or any item's
/// barcode — to open the plate holding it.
class LicensePlatesPage extends StatefulWidget {
  const LicensePlatesPage({super.key, required this.session, required this.warehouse});

  final BrijjSession session;
  final Warehouse warehouse;

  @override
  State<LicensePlatesPage> createState() => _LicensePlatesPageState();
}

class _LicensePlatesPageState extends State<LicensePlatesPage> {
  List<Map<String, dynamic>>? _plates;
  String _search = '';
  String? _error;
  String? _flash;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final api = TpmApi(widget.session.env);
    try {
      final plates = await api.licensePlates(widget.session, widget.warehouse.id);
      if (mounted) setState(() => _plates = plates);
    } on TpmApiException catch (e) {
      if (mounted) setState(() => _error = e is OfflineException ? 'Offline — needs a connection.' : e.message);
    } finally {
      api.close();
    }
  }

  void _open(Map<String, dynamic> lp) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => LicensePlatePage(plate: lp)));

  Future<void> _onScan(String barcode) async {
    final plates = _plates ?? const <Map<String, dynamic>>[];
    final lp = plates.where((p) => '${p['referenceNumber']}'.toUpperCase() == barcode.toUpperCase()).firstOrNull;
    if (lp != null) {
      HapticFeedback.lightImpact();
      _open(lp);
      return;
    }
    // An item barcode: find the plate it's packed in.
    final api = TpmApi(widget.session.env);
    try {
      final serial = (await api.imsFind(widget.session, barcode, [widget.warehouse.id])).firstOrNull;
      final holder = serial == null ? null : await api.licensePlateForSerial(widget.session, serial.serialId);
      if (!mounted) return;
      if (holder == null) {
        HapticFeedback.heavyImpact();
        setState(() => _flash = serial == null ? '$barcode isn\'t a plate or an item here' : '$barcode isn\'t on a license plate');
      } else {
        HapticFeedback.lightImpact();
        setState(() => _flash = null);
        _open(holder);
      }
    } on TpmApiException catch (e) {
      if (mounted) setState(() => _flash = e.message);
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.toLowerCase();
    final shown = [
      for (final p in _plates ?? const <Map<String, dynamic>>[])
        if (q.isEmpty ||
            '${p['referenceNumber']} ${p['description'] ?? ''} ${(p['warehouseLocation'] as Map?)?['name'] ?? ''}'.toLowerCase().contains(q))
          p,
    ];
    return Scaffold(
      appBar: AppBar(title: Text('License Plates — ${widget.warehouse.name}')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ScanInput(onScan: _onScan, label: 'Scan a plate or an item on it'),
            if (_flash != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_flash!, style: const TextStyle(color: statusDanger, fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Search', border: OutlineInputBorder()),
              onChanged: (v) => setState(() => _search = v),
            ),
            if (_error != null) ListTile(leading: const Icon(Icons.cloud_off, color: statusWarning), title: Text(_error!)),
            if (_plates == null && _error == null)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
            if (_plates != null && shown.isEmpty) const ListTile(leading: Icon(Icons.inbox), title: Text('No license plates')),
            for (final lp in shown)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.pallet, size: 32),
                  title: Text('${lp['referenceNumber']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    [
                      if ('${lp['description'] ?? ''}'.isNotEmpty) '${lp['description']}',
                      '${(lp['warehouseLocation'] as Map?)?['name'] ?? '—'} · ${plateStatus(lp['status'])}',
                      '${(lp['items'] as List? ?? const []).length} product(s), ${_units(lp)} unit(s)',
                    ].join('\n'),
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(lp),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One license plate: where it is, its status, and every product and barcode on it.
class LicensePlatePage extends StatelessWidget {
  const LicensePlatePage({super.key, required this.plate});

  final Map<String, dynamic> plate;

  @override
  Widget build(BuildContext context) {
    final items = [for (final i in plate['items'] as List? ?? const []) if (i is Map) i];
    Widget field(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 100, child: Text(label, style: const TextStyle(color: brijjText))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text('${plate['referenceNumber']}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if ('${plate['description'] ?? ''}'.isNotEmpty) field('Description', '${plate['description']}'),
          field('Location', '${(plate['warehouseLocation'] as Map?)?['name'] ?? '—'}'),
          field('Status', plateStatus(plate['status'])),
          field('Contents', '${items.length} product(s), ${_units(plate.cast<String, dynamic>())} unit(s)'),
          field('Created', '${_when(plate['createdAt'])}${plate['createdBy'] is Map ? ' · ${(plate['createdBy'] as Map)['name'] ?? ''}' : ''}'),
          const Divider(height: 32),
          for (final i in items)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            shortProductName('${(i['product'] as Map?)?['name'] ?? 'Product ${i['productId']}'}'),
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                          ),
                        ),
                        Text('× ${i['quantity'] ?? 0}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    if ('${(i['product'] as Map?)?['sku'] ?? ''}'.isNotEmpty) Text('${(i['product'] as Map)['sku']}'),
                    SelectableText(
                      [
                        for (final s in i['itemSerials'] as List? ?? const [])
                          if (s is Map && s['serialNumber'] != null) '${s['serialNumber']}',
                      ].join('  '),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
