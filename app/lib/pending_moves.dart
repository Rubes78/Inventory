import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'brand.dart';
import 'tpm_api.dart';

/// Movement orders the app submitted that IMS hadn't finished yet (queued or
/// processing). Saved on the device and re-checked until IMS confirms them, so a
/// "Queued" answer is never taken as done without a follow-up.
class PendingMoveStore {
  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/pending_moves.json');

  static Future<List<PendingMove>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      return [
        for (final j in jsonDecode(await f.readAsString()) as List) PendingMove.fromJson((j as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<PendingMove> moves) async =>
      (await _file()).writeAsString(jsonEncode([for (final m in moves) m.toJson()]));

  static Future<void> add(List<PendingMove> moves) async {
    if (moves.isEmpty) return;
    await save([...await load(), ...moves]);
  }

  static Future<void> remove(int orderId) async =>
      save([for (final m in await load()) if (m.orderId != orderId) m]);

  static Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }

  /// Asks IMS about every order not yet known to be finished. Completed orders are
  /// dropped from the store; cancelled/failed ones stay so the user sees them.
  /// Returns the orders that reached a final status in this check.
  static Future<List<PendingMove>> checkAll(TpmApi api, BrijjSession session) async {
    final moves = await load();
    final finished = <PendingMove>[];
    for (final m in moves) {
      if (MoveStatus.isFinal(m.status)) continue;
      try {
        final check = await api.checkMove(session, m.orderId);
        if (check.status != m.status) {
          m.status = check.status;
          if (MoveStatus.isFinal(check.status)) finished.add(m);
        }
      } on OfflineException {
        break;
      } on SessionExpiredException {
        rethrow;
      } on TpmApiException {
        // Try again next time.
      }
    }
    await save([
      for (final m in moves)
        if (m.status != MoveStatus.completed) m,
    ]);
    return finished;
  }

  /// One-line summary of what [checkAll] found, for a snack bar; null if nothing.
  static String? summary(List<PendingMove> finished) {
    if (finished.isEmpty) return null;
    final done = finished.where((m) => m.status == MoveStatus.completed).toList();
    final bad = finished.length - done.length;
    return [
      if (done.isNotEmpty) '${done.map((m) => m.ref).join(', ')} confirmed by IMS',
      if (bad > 0) '$bad pull(s) ${bad == 1 ? 'was' : 'were'} not completed — see Awaiting IMS',
    ].join(' · ');
  }
}

/// Submitted pulls still awaiting IMS confirmation, with a manual refresh. Failed or
/// cancelled orders can be dismissed or their barcodes put back on the Scan Pull list.
class PendingMovesPage extends StatefulWidget {
  const PendingMovesPage({super.key, required this.session, required this.onReAdd});

  final BrijjSession session;

  /// Puts barcodes back on the Scan Pull list (for a failed or cancelled order).
  final Future<void> Function(List<String> barcodes) onReAdd;

  @override
  State<PendingMovesPage> createState() => _PendingMovesPageState();
}

class _PendingMovesPageState extends State<PendingMovesPage> {
  List<PendingMove> _moves = [];
  bool _checking = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = null;
    });
    final before = await PendingMoveStore.load();
    if (mounted) setState(() => _moves = before);
    final api = TpmApi(widget.session.env);
    try {
      final finished = await PendingMoveStore.checkAll(api, widget.session);
      _message = PendingMoveStore.summary(finished);
    } on TpmApiException catch (e) {
      _message = e.message;
    } finally {
      api.close();
    }
    final after = await PendingMoveStore.load();
    if (!mounted) return;
    setState(() {
      _moves = after;
      _checking = false;
    });
  }

  Future<void> _dismiss(PendingMove m) async {
    await PendingMoveStore.remove(m.orderId);
    final after = await PendingMoveStore.load();
    if (mounted) setState(() => _moves = after);
  }

  Future<void> _reAdd(PendingMove m) async {
    await widget.onReAdd(m.barcodes);
    await _dismiss(m);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${m.barcodes.length} barcode(s) put back on the Scan Pull list')),
      );
    }
  }

  String _when(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Awaiting IMS'),
        actions: [
          IconButton(
            tooltip: 'Check now',
            onPressed: _checking ? null : _check,
            icon: _checking
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(_message!, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          if (_moves.isEmpty && !_checking)
            const ListTile(
              leading: Icon(Icons.check_circle, color: statusSuccess),
              title: Text('Nothing waiting'),
              subtitle: Text('Every submitted pull has been confirmed by IMS.'),
            ),
          for (final m in _moves) _tile(m),
        ],
      ),
    );
  }

  Widget _tile(PendingMove m) {
    final bad = m.status == MoveStatus.cancelled || m.status == MoveStatus.failed;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(bad ? Icons.error : Icons.hourglass_top, color: bad ? statusDanger : statusWarning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(m.ref, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                Text(
                  MoveStatus.label(m.status),
                  style: TextStyle(color: bad ? statusDanger : statusWarning, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('${m.barcodes.length} item(s) → ${m.destination}'),
            Text('${m.reason} · submitted ${_when(m.submittedAt)}'),
            if (bad)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonal(onPressed: () => _reAdd(m), child: const Text('Put back on list')),
                    TextButton(onPressed: () => _dismiss(m), child: const Text('Dismiss')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
