import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'brand.dart';
import 'count_model.dart';
import 'tpm_api.dart';

/// Inventory Count on the device: the IMS portal creates and approves counts; this
/// does the counting step of the IMS web app's count work items, by scanning.

String _date(Object? iso) {
  final t = DateTime.tryParse('$iso')?.toLocal();
  return t == null ? '' : '${t.month}/${t.day}/${t.year % 100}';
}

String _scopeLabel(Object? scope) => switch (scope) {
  1 => 'Specific products',
  2 => 'Specific locations',
  3 => 'Specific zones',
  4 => 'Entire warehouse',
  _ => 'Count',
};

/// Open Inventory Count work items in a warehouse.
class CountListPage extends StatefulWidget {
  const CountListPage({super.key, required this.session, this.preferredWarehouseId});

  final BrijjSession session;

  /// The Scan Pull destination's warehouse, offered first.
  final int? preferredWarehouseId;

  @override
  State<CountListPage> createState() => _CountListPageState();
}

class _CountListPageState extends State<CountListPage> {
  Map<int, String> _warehouses = {};
  int? _warehouseId;
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
      if (_warehouses.isEmpty) {
        _warehouses = await api.warehouses(widget.session);
        _warehouseId = _warehouses.containsKey(widget.preferredWarehouseId)
            ? widget.preferredWarehouseId
            : (_warehouses.keys.isEmpty ? null : _warehouses.keys.first);
      }
      final wh = _warehouseId;
      final items = wh == null ? <Map<String, dynamic>>[] : await api.countWorkItems(widget.session, wh);
      if (mounted) setState(() => _items = items);
    } on TpmApiException catch (e) {
      if (mounted) setState(() => _error = e is OfflineException ? 'Offline — counts need a connection to load.' : e.message);
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Inventory Count')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (_warehouses.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final w in _warehouses.entries)
                      ChoiceChip(
                        label: Text(w.value),
                        selected: _warehouseId == w.key,
                        onSelected: (_) {
                          setState(() {
                            _warehouseId = w.key;
                            _items = null;
                          });
                          _load();
                        },
                      ),
                  ],
                ),
              ),
            if (_error != null)
              ListTile(
                leading: const Icon(Icons.cloud_off, color: statusWarning),
                title: Text(_error!),
                trailing: TextButton(onPressed: _load, child: const Text('Retry')),
              ),
            if (items == null && _error == null)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
            if (items != null && items.isEmpty)
              const ListTile(
                leading: Icon(Icons.inbox),
                title: Text('No open counts'),
                subtitle: Text('Counts are created in the IMS portal (Inventory Management › Inventory Counts).'),
              ),
            for (final w in items ?? const <Map<String, dynamic>>[]) _tile(w),
          ],
        ),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> w) {
    final line = ((w['worklistLineItems'] as List?) ?? const []).cast<Map>().firstOrNull ?? const {};
    final mine = '${line['userId']}' == widget.session.userId;
    // IMS sends the literal "NotAssigned" for unassigned tasks.
    final who = '${line['userName'] ?? ''}'.trim().replaceAll('NotAssigned', '');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: ListTile(
        leading: const Icon(Icons.fact_check, size: 32),
        title: Text('${w['typeReferenceNumber'] ?? w['referenceNumber']}', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [
            '${w['statusName'] ?? ''} · created ${_date(w['createdAt'])}',
            if (who.isNotEmpty) mine ? 'Assigned to you' : 'Assigned to $who',
          ].join('\n'),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final done = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => CountPage(session: widget.session, worklistId: (w['id'] as num).toInt(), warehouseId: _warehouseId!),
            ),
          );
          if (done == true) _load();
        },
      ),
    );
  }
}

/// Counting one Inventory Count work item.
class CountPage extends StatefulWidget {
  const CountPage({super.key, required this.session, required this.worklistId, required this.warehouseId});

  final BrijjSession session;
  final int worklistId;
  final int warehouseId;

  @override
  State<CountPage> createState() => _CountPageState();
}

class _CountPageState extends State<CountPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  Map<String, dynamic>? _worklist;
  Map<String, dynamic>? _count;
  List<CountLine> _lines = [];
  String? _error;
  String? _loadingStep;
  bool _busy = false;
  String? _lastScan;
  Color _lastScanColor = statusSuccess;

  /// Hardware scanners that broadcast (CipherLab, clipboard, …) — see MainActivity.kt.
  static const _scanner = EventChannel('scan_pull/scanner');
  static const _keyboard = MethodChannel('scan_pull/keyboard');
  StreamSubscription<dynamic>? _scans;

  int get _countId => (_count?['id'] as num?)?.toInt() ?? 0;

  /// Sales floor and storage locations — the only ones counted.
  Map<int, String> _countable = {};

  Map<String, dynamic>? get _task {
    final lines = ((_worklist?['worklistLineItems'] as List?) ?? const []).cast<Map>();
    final t = lines.where((l) => l['type'] == 11 || l['type'] == 12).firstOrNull ?? lines.firstOrNull;
    return t?.cast<String, dynamic>();
  }

  /// Started by this user (the web app's "Start counting" was done).
  bool get _started => _task != null && _task!['status'] == 3 && '${_task!['userId']}' == widget.session.userId;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) _hideKeyboard();
    });
    _scans = _scanner.receiveBroadcastStream().listen((data) {
      if (data is Map && data['barcode'] is String) _onScan(data['barcode'] as String);
    }, onError: (_) {});
    _load();
  }

  @override
  void dispose() {
    _scans?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _hideKeyboard() {
    for (final ms in [0, 150, 400]) {
      Future.delayed(Duration(milliseconds: ms), () {
        if (!mounted) return;
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        _keyboard.invokeMethod<void>('hide').catchError((_) {});
      });
    }
  }

  Future<File> _progressFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/count_progress_$_countId.json');

  Future<void> _saveProgress() async {
    try {
      await (await _progressFile()).writeAsString(jsonEncode(progressToJson(_lines)));
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _loadingStep = 'Loading count…';
    });
    final api = TpmApi(widget.session.env);
    try {
      final wl = await api.worklist(widget.session, widget.worklistId);
      _worklist = wl;
      final countId = ((wl['worklistLineItems'] as List).cast<Map>().first['referenceId'] as num).toInt();
      final count = await api.inventoryCount(widget.session, countId);
      _count = count;
      _countable = await api.countableLocations(widget.session);
      final ids = {
        for (final i in count['items'] as List? ?? const [])
          if (i is Map && i['productId'] is num) (i['productId'] as num).toInt(),
      };
      final products = <int, Map<String, dynamic>>{};
      var n = 0;
      for (final id in ids) {
        if (mounted) setState(() => _loadingStep = 'Loading products ${++n} of ${ids.length}…');
        products[id] = await api.product(widget.session, id, widget.warehouseId);
      }
      final lines = buildCountLines(count, products, allowedLocations: _countable.keys.toSet());
      try {
        final f = await _progressFile();
        if (await f.exists()) progressFromJson(lines, jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _lines = lines;
          _loadingStep = null;
        });
      }
      _focus.requestFocus();
    } on TpmApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e is OfflineException ? 'Offline — the count needs a connection to load.' : e.message;
          _loadingStep = null;
        });
      }
    } finally {
      api.close();
    }
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    final api = TpmApi(widget.session.env);
    try {
      await api.startCount(widget.session, _worklist!, _count!);
      _worklist = await api.worklist(widget.session, widget.worklistId);
      // ChangeAssignment sets the user; the web app also shows the task as In progress.
      _task?['status'] = 3;
      _task?['userId'] = int.tryParse(widget.session.userId) ?? widget.session.userId;
    } on TpmApiException catch (e) {
      _snack(e.message);
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
    _focus.requestFocus();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  void _flash(String message, Color color) {
    setState(() {
      _lastScan = message;
      _lastScanColor = color;
    });
  }

  Future<void> _onScan(String raw) async {
    final barcode = raw.trim();
    if (barcode.isEmpty || _lines.isEmpty || _busy) return;
    if (!_started) {
      HapticFeedback.heavyImpact();
      _flash('Tap Start counting first', statusWarning);
      return;
    }
    switch (routeScan(_lines, barcode)) {
      case ScanResult.counted:
        HapticFeedback.lightImpact();
        final l = _lines.firstWhere((l) => l.scanned.contains(barcode));
        _flash('$barcode · ${shortProductName(l.product)} · ${l.location}', statusSuccess);
        _saveProgress();
        return;
      case ScanResult.duplicate:
        HapticFeedback.heavyImpact();
        _flash('$barcode already counted', statusWarning);
        return;
      case ScanResult.unknown:
        break;
    }
    // Not expected anywhere in this count: ask IMS what it is.
    _flash('$barcode · checking IMS…', brijjText);
    final api = TpmApi(widget.session.env);
    try {
      final found = await api.imsFind(widget.session, barcode, [widget.warehouseId]);
      if (!mounted) return;
      final serial = found.firstOrNull;
      final line = serial == null ? null : placeExtra(_lines, barcode, serial.productId, serial.locationId);
      if (line != null) {
        HapticFeedback.mediumImpact();
        _flash('$barcode · not expected here (IMS: ${serial!.locationName}) — counted on ${line.location}', statusWarning);
        setState(() {});
        _saveProgress();
      } else {
        HapticFeedback.heavyImpact();
        _flash(
          serial == null
              ? '$barcode · not in IMS for this warehouse'
              : _countable.containsKey(serial.locationId)
              ? '$barcode · not part of this count (IMS: ${serial.locationName})'
              : '$barcode · not counted — IMS has it in ${serial.locationName}, not the sales floor or storage',
          statusDanger,
        );
      }
    } on OfflineException {
      HapticFeedback.heavyImpact();
      _flash('$barcode · offline — can\'t identify it; scan again when online', statusDanger);
    } on TpmApiException catch (e) {
      _flash('$barcode · ${e.message}', statusDanger);
    } finally {
      api.close();
    }
  }

  void _onSubmitted(String value) {
    _onScan(value);
    _input.clear();
    _focus.requestFocus();
  }

  Future<void> _submit() async {
    final short = _lines.where((l) => l.difference < 0).length;
    final over = _lines.where((l) => l.difference > 0).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.session.env == BrijjEnv.production ? 'Submit count — PRODUCTION?' : 'Submit count?'),
        content: Text(
          '${_lines.length} line(s) will be submitted to ${_count?['referenceNumber']} as counted by ${widget.session.fullName}.'
          '${short == 0 ? '' : '\n\n$short line(s) are short — missing barcodes are reported as not found.'}'
          '${over == 0 ? '' : '\n\n$over line(s) have more than expected.'}'
          '\n\nThe count then goes to IMS Counting Approval.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep counting')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Submit')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final api = TpmApi(widget.session.env);
    try {
      final userId = int.tryParse(widget.session.userId) ?? widget.session.userId;
      await api.submitCount(widget.session, _worklist!, _count!, [
        for (final l in _lines) l.payload(countId: _countId, userId: userId),
      ]);
      try {
        final f = await _progressFile();
        if (await f.exists()) await f.delete();
      } catch (_) {}
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Count submitted'),
          content: Text('${_count?['referenceNumber']} is ready for approval in IMS (Counting Approval).'),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on TpmApiException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Count not submitted'),
          content: Text(
            '${e is OfflineException ? 'No connection.' : e.message}\n\nYour counting is saved on this device — '
            'submit again when you can.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _count;
    final counted = _lines.fold<int>(0, (t, l) => t + l.actual);
    final expected = _lines.fold<int>(0, (t, l) => t + l.expected);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${count?['referenceNumber'] ?? 'Inventory Count'}'),
            if (count != null) Text('${count['name'] ?? ''}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      bottomNavigationBar: _lines.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  onPressed: _busy ? null : (_started ? _submit : _start),
                  icon: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(_started ? Icons.cloud_upload : Icons.play_arrow),
                  label: Text(_started ? 'Submit count' : 'Start counting', style: const TextStyle(fontSize: 18)),
                ),
              ),
            ),
      body: _loadingStep != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text(_loadingStep!)],
              ),
            )
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
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: brijjBlueTint,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Text(
                    '${_scopeLabel(count?['scope'])} · sales floor & storage only · ${_lines.length} line(s) · '
                    'counted $counted of $expected expected',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    autofocus: true,
                    enabled: _started,
                    keyboardType: TextInputType.none,
                    decoration: InputDecoration(
                      labelText: _started ? 'Scan a barcode' : 'Tap Start counting to begin',
                      prefixIcon: const Icon(Icons.qr_code_scanner),
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: _onSubmitted,
                  ),
                ),
                if (_lastScan != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(_lastScan!, style: TextStyle(color: _lastScanColor, fontWeight: FontWeight.w600)),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      if (_lines.isEmpty)
                        const ListTile(
                          leading: Icon(Icons.info_outline),
                          title: Text('Nothing to count'),
                          subtitle: Text(
                            'IMS has no stock for this count\'s products on the sales floor or in storage in this warehouse.',
                          ),
                        ),
                      for (final l in _lines) _lineCard(l),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _lineCard(CountLine l) {
    final diff = l.difference;
    final color = diff == 0 ? statusSuccess : (diff < 0 ? statusWarning : brijjBlue);
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
                  child: Text(shortProductName(l.product), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                Text(
                  '${l.actual} / ${l.expected}',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color),
                ),
              ],
            ),
            Text('${l.location} · ${l.sku}'),
            if (l.serialized) ...[
              if (l.extra.isNotEmpty)
                Text('Not expected here: ${l.extra.join(', ')}', style: const TextStyle(color: brijjBlue)),
              if (l.missing.isNotEmpty && l.missing.length <= 10)
                Text('Not scanned yet: ${l.missing.join(', ')}', style: const TextStyle(color: brijjText)),
              if (l.missing.length > 10) Text('${l.missing.length} expected barcodes not scanned yet'),
            ] else
              Row(
                children: [
                  const Text('Quantity'),
                  const Spacer(),
                  IconButton(
                    onPressed: !_started || l.manual == 0
                        ? null
                        : () {
                            setState(() => l.manual--);
                            _saveProgress();
                          },
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('${l.manual}', style: const TextStyle(fontSize: 18)),
                  IconButton(
                    onPressed: !_started
                        ? null
                        : () {
                            setState(() => l.manual++);
                            _saveProgress();
                          },
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
