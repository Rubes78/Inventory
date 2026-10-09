import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'brand.dart';
import 'lookup.dart';
import 'tpm_api.dart';
import 'updater.dart';
import 'user_photo.dart';

void main() => runApp(const ScanPullApp());

/// The environment on screen: the signed-in session's, or the one picked on the
/// sign-in page. Production gets a red corner ribbon on every screen.
final activeEnv = ValueNotifier<BrijjEnv>(BrijjEnv.staging);

class ScanPullApp extends StatelessWidget {
  const ScanPullApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brijj Inventory',
      theme: brijjTheme(),
      builder: (context, child) => ValueListenableBuilder<BrijjEnv>(
        valueListenable: activeEnv,
        builder: (context, env, _) => env == BrijjEnv.production
            ? Banner(message: 'PRODUCTION', location: BannerLocation.topEnd, color: statusDanger, child: child!)
            : child!,
      ),
      home: const AuthGate(),
    );
  }
}

/// The environment last picked on the sign-in page, so testers don't have to
/// re-pick it every time staging is down.
class EnvStore {
  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/env.txt');

  static Future<BrijjEnv> load() async {
    try {
      final f = await _file();
      return BrijjEnv.byName(await f.exists() ? (await f.readAsString()).trim() : null);
    } catch (_) {
      return BrijjEnv.staging;
    }
  }

  static Future<void> save(BrijjEnv env) async {
    try {
      await (await _file()).writeAsString(env.name);
    } catch (_) {}
  }
}

/// The signed-in user, kept in app-private storage so the user stays signed in
/// across app restarts until they sign out.
class SessionStore {
  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/session.json');

  static Future<BrijjSession?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      return BrijjSession.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(BrijjSession session) async => (await _file()).writeAsString(jsonEncode(session.toJson()));

  static Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}

/// Shows the sign-in page until a Brijj user is signed in, then the scan list.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  BrijjSession? _session;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Updater.check(force: true);
    SessionStore.load().then((s) {
      if (s != null) {
        activeEnv.value = s.env;
        UserPhoto.load(s);
      }
      setState(() {
        _session = s;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Updater.check();
  }

  Future<void> _signedIn(BrijjSession session) async {
    await SessionStore.save(session);
    activeEnv.value = session.env;
    UserPhoto.load(session);
    setState(() => _session = session);
  }

  Future<void> _signedOut() async {
    await SessionStore.clear();
    await UserPhoto.clear();
    activeEnv.value = await EnvStore.load();
    setState(() => _session = null);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final session = _session;
    if (session == null) return LoginPage(onSignedIn: _signedIn);
    return HomePage(key: ValueKey(session.sessionId), session: session, onSignedOut: _signedOut);
  }
}

/// Start screen after sign-in: pick a task. Scan Pull is live; Transfers and
/// Inventory Count are placeholders for upcoming work.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.session, required this.onSignedOut});

  final BrijjSession session;
  final Future<void> Function() onSignedOut;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Unsubmitted Scan Pull barcodes saved on the device.
  int _pending = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final n = await ScanStore.savedCount();
    if (mounted) setState(() => _pending = n);
  }

  /// Signing out from any screen returns here first, then to sign-in.
  Future<void> _signedOut() async {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await widget.onSignedOut();
  }

  Future<void> _openScanPull() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScanListPage(session: widget.session, onSignedOut: _signedOut),
      ),
    );
    _refresh();
  }

  Future<void> _signOut() async {
    final version = await Updater.currentVersion();
    Updater.check(force: true);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: _accountTitle(widget.session),
        content: Text(
          '${widget.session.companyLabel}\nApp version $version'
          '${_pending == 0 ? '' : '\n\nSigning out clears the $_pending unsubmitted Scan Pull barcode(s) on this device.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true) return;
    // The next person on this device must not submit this user's list under their own name.
    await ScanStore.deleteSaved();
    await LookupCache.clear();
    final api = TpmApi(widget.session.env);
    await api.signOut(widget.session);
    api.close();
    await widget.onSignedOut();
  }

  Widget _task(IconData icon, String title, String subtitle, {VoidCallback? onTap, String? badge}) {
    final enabled = onTap != null;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        // Match the card's rounded corners (list tiles are white by theme).
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        enabled: enabled,
        leading: Icon(icon, size: 40),
        title: Text(
          title,
          style: const TextStyle(fontFamily: headingFont, fontSize: 22, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle),
        trailing: badge != null
            ? Badge(label: Text(badge), largeSize: 24, textStyle: const TextStyle(fontSize: 14))
            : enabled
            ? const Icon(Icons.chevron_right)
            : null,
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(12),
          child: Image.asset('assets/brijj_mark.png', fit: BoxFit.contain),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Brijj Inventory'),
            Text(
              '${widget.session.fullName} · ${widget.session.companyName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Account / sign out',
            icon: UserAvatar(name: widget.session.fullName),
            onPressed: _signOut,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const UpdateCard(),
          _task(
            Icons.remove_shopping_cart,
            'Scan Pull',
            'Pull items from the sales floor',
            onTap: _openScanPull,
            badge: _pending > 0 ? '$_pending' : null,
          ),
          _task(Icons.swap_horiz, 'Transfers', 'Coming soon'),
          _task(Icons.fact_check, 'Inventory Count', 'Coming soon'),
        ],
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onSignedIn});

  final Future<void> Function(BrijjSession session) onSignedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  BrijjEnv _env = activeEnv.value;

  @override
  void initState() {
    super.initState();
    EnvStore.load().then((env) {
      if (mounted) _pickEnv(env);
    });
  }

  void _pickEnv(BrijjEnv env) {
    activeEnv.value = env;
    setState(() {
      _env = env;
      _error = null;
    });
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final username = _username.text.trim();
    if (username.isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your Brijj username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = TpmApi(_env);
    try {
      final session = await api.signIn(username, _password.text);
      if (!await api.canScanPull(session)) {
        await api.signOut(session);
        throw TpmApiException(
          '${session.fullName} does not have Scan Pull access. '
          'Ask an admin to add the ${TpmApi.scanPullPermission} permission (TPM Portal > '
          'Production System) to one of your roles.',
        );
      }
      await EnvStore.save(_env);
      await widget.onSignedIn(session);
    } on TpmApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const UpdateCard(),
            const SizedBox(height: 12),
            Center(child: Image.asset('assets/brijj_logo.png', height: 88, semanticLabel: 'Brijj')),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Inventory',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: brijjBlue, letterSpacing: 1),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Sign in with your Brijj account.', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 4),
            const SizedBox(height: 16),
            SegmentedButton<BrijjEnv>(
              segments: [
                for (final e in BrijjEnv.values)
                  ButtonSegment(
                    value: e,
                    label: Text(e.label),
                    icon: Icon(e == BrijjEnv.production ? Icons.warning_amber : Icons.science),
                  ),
              ],
              selected: {_env},
              showSelectedIcon: false,
              onSelectionChanged: _busy ? null : (s) => _pickEnv(s.first),
            ),
            const SizedBox(height: 6),
            Text(
              _env == BrijjEnv.production
                  ? 'Production (${_env.domain}) — Scan Pulls change real inventory.'
                  : 'Staging (${_env.domain}) — test data; down overnight.',
              style: TextStyle(
                color: _env == BrijjEnv.production ? statusDanger : brijjText,
                fontWeight: _env == BrijjEnv.production ? FontWeight.w600 : null,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _username,
              enabled: !_busy,
              autofocus: true,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _signIn(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  tooltip: _showPassword ? 'Hide password' : 'Show password',
                  icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 15)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: _busy ? null : _signIn,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Sign in', style: TextStyle(fontSize: 18)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The scanned barcodes, saved to a file after every change so a closed or
/// crashed app doesn't lose a half-built pull list.
class ScanStore {
  final List<String> barcodes = [];
  late final File _file;

  static Future<File> _savedFile() async => File('${(await getApplicationDocumentsDirectory()).path}/scans.txt');

  /// How many barcodes are saved, without opening the Scan Pull screen.
  static Future<int> savedCount() async {
    try {
      final f = await _savedFile();
      return await f.exists() ? (await f.readAsLines()).where((l) => l.isNotEmpty).length : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> deleteSaved() async {
    final f = await _savedFile();
    if (await f.exists()) await f.delete();
  }

  Future<void> load() async {
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/scans.txt');
    if (await _file.exists()) {
      barcodes.addAll((await _file.readAsLines()).where((l) => l.isNotEmpty));
    }
  }

  /// Returns false if the barcode is already in the list.
  bool add(String barcode) {
    if (barcodes.contains(barcode)) return false;
    barcodes.add(barcode);
    _save();
    return true;
  }

  void removeAt(int index) {
    barcodes.removeAt(index);
    _save();
  }

  void clear() {
    barcodes.clear();
    _save();
  }

  void removeAll(Iterable<String> remove) {
    final set = remove.toSet();
    barcodes.removeWhere(set.contains);
    _save();
  }

  Future<void> _save() => _file.writeAsString(barcodes.map((b) => '$b\n').join());

  /// Barcode-only CSV: one barcode per line, no header.
  Future<File> exportCsv() async {
    final dir = await getTemporaryDirectory();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final file = File('${dir.path}/scanpull_$stamp.csv');
    return file.writeAsString(barcodes.map((b) => '$b\r\n').join());
  }
}

/// Last known TPM details, week color names and week numbers, kept on the device
/// so the list still shows details offline and after a restart.
class LookupCache {
  final items = <String, Lookup>{};
  final colors = <int, String>{};
  final weeks = <String, int>{};

  /// Where Submit sends items: null = TPM Scan Pull, else an IMS Scan Pull location.
  ScanPullLocation? destination;

  /// The company's Scan Pull locations, for choosing a destination offline.
  final locations = <ScanPullLocation>[];

  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/lookup_cache.json');

  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      (j['items'] as Map? ?? {}).forEach((k, v) {
        final l = Lookup.fromJson((v as Map).cast<String, dynamic>());
        if (l != null) items['$k'] = l;
      });
      (j['colors'] as Map? ?? {}).forEach((k, v) => colors[int.parse('$k')] = '$v');
      (j['weeks'] as Map? ?? {}).forEach((k, v) => weeks['$k'] = (v as num).toInt());
      if (j['destination'] is Map) {
        destination = ScanPullLocation.fromJson((j['destination'] as Map).cast<String, dynamic>());
      }
      for (final l in j['locations'] as List? ?? const []) {
        locations.add(ScanPullLocation.fromJson((l as Map).cast<String, dynamic>()));
      }
    } catch (_) {
      // A damaged cache just means details are fetched again.
    }
  }

  Future<void> save() async => (await _file()).writeAsString(
    jsonEncode({
      'items': {for (final e in items.entries) e.key: ?e.value.toJson()},
      'colors': {for (final e in colors.entries) '${e.key}': e.value},
      'weeks': weeks,
      'destination': destination?.toJson(),
      'locations': [for (final l in locations) l.toJson()],
    }),
  );

  static Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}

/// Account dialog title: the user's picture (or initials) and name.
Widget _accountTitle(BrijjSession session) => Row(
  children: [
    UserAvatar(name: session.fullName, radius: 28),
    const SizedBox(width: 16),
    Expanded(child: Text(session.fullName)),
  ],
);

String _money(double v) => '\$${v.toStringAsFixed(2)}';

Color? _hexColor(String? hex) {
  final h = hex?.replaceFirst('#', '');
  if (h == null || h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

String _describe(ItemDetails d) => [
  [d.department, d.category, d.subCategory].whereType<String>().where((x) => x.isNotEmpty).join(' › '),
  _money(d.price),
].join(' · ');

String _where(ItemDetails d) {
  final p = d.produced;
  return [
    d.brand,
    d.size,
    d.quality,
    [d.store, d.location].whereType<String>().join(' / '),
    if (p != null) 'produced ${p.month}/${p.day}',
  ].whereType<String>().where((x) => x.isNotEmpty).join(' · ');
}

/// Week color chip: the TPM color with its name and week number, e.g. "Green · week 41".
Widget _colorChip(ItemDetails d, LookupCache cache) {
  final color = _hexColor(d.color);
  if (color == null && d.productionCycleId == null) return const SizedBox.shrink();
  final name = d.colorName ?? cache.colors[d.productionCycleId] ?? 'Cycle ${d.productionCycleId ?? '?'}';
  final week = d.producedDay == null ? null : cache.weeks[d.producedDay];
  final dark = color == null || color.computeLuminance() < 0.5;
  return Container(
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color ?? brijjText,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: brijjLine),
    ),
    child: Text(
      week == null ? name : '$name · week $week',
      style: TextStyle(color: dark ? Colors.white : brijjInk, fontWeight: FontWeight.w600, fontSize: 13),
    ),
  );
}

class ScanListPage extends StatefulWidget {
  const ScanListPage({super.key, required this.session, required this.onSignedOut});

  final BrijjSession session;
  final Future<void> Function() onSignedOut;

  @override
  State<ScanListPage> createState() => _ScanListPageState();
}

class _ScanListPageState extends State<ScanListPage> {
  final _store = ScanStore();
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _loaded = false;
  bool _submitting = false;

  /// TPM details per scanned barcode, looked up as each one is scanned. Saved on the
  /// device; offline scans are queued and looked up when the connection is back.
  final _cache = LookupCache();
  Map<String, Lookup> get _lookups => _cache.items;
  late final _api = TpmApi(widget.session.env);
  bool _expired = false;

  /// Whether TPM is reachable. Submitting needs it; lookups queue without it.
  bool _online = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _retry;
  bool _catchingUp = false;

  ScanPullLocation? get _dest => _cache.destination;

  Future<void> _lookup(String barcode, {bool quiet = false}) async {
    final known = _lookups[barcode]?.details;
    final knownIms = _lookups[barcode]?.ims;
    if (!_online) {
      // Known to be offline: just queue it. The periodic check resumes lookups.
      setState(() => _lookups[barcode] = Lookup.waiting(known, knownIms));
      _cache.save();
      return;
    }
    setState(() => _lookups[barcode] = Lookup.checking(known, knownIms));
    Lookup result;
    try {
      final d = await _api.lookup(widget.session, barcode);
      final dest = _dest;
      final ims = d == null || dest == null ? null : await _api.imsFind(widget.session, barcode, dest.allWarehouseIds);
      result = d == null ? Lookup.missing : Lookup.found(d, ims);
      _setOnline(true);
    } on SessionExpiredException catch (e) {
      if (!_expired && mounted) {
        _expired = true;
        _snack(e.message);
        await widget.onSignedOut();
      }
      return;
    } on OfflineException {
      result = Lookup.waiting(known, knownIms);
      _setOnline(false);
    } on TpmApiException catch (e) {
      result = Lookup.failed(e.message, known, knownIms);
    }
    if (!mounted || !_store.barcodes.contains(barcode)) return;
    setState(() => _lookups[barcode] = result);
    _cache.save();
    if (result.details case final d?) _loadColorDetails(d);
    if (!quiet && result.skipReason(_dest) != null) HapticFeedback.heavyImpact();
  }

  /// Fills in the week color name and week number for [d], once per company/date.
  Future<void> _loadColorDetails(ItemDetails d) async {
    try {
      if (d.colorName == null && d.productionCycleId != null && !_cache.colors.containsKey(d.productionCycleId)) {
        _cache.colors.addAll(await _api.colorNames(widget.session));
      }
      final day = d.producedDay;
      if (day != null && !_cache.weeks.containsKey(day)) {
        final week = await _api.weekNumber(widget.session, day);
        if (week != null) _cache.weeks[day] = week;
      }
      if (!mounted) return;
      setState(() {});
      _cache.save();
    } on TpmApiException {
      // Color details are extras; they're retried with the next lookup.
    }
  }

  void _setOnline(bool online) {
    if (online == _online || !mounted) return;
    setState(() => _online = online);
    _log(online ? 'Back online' : 'Offline');
    if (online) {
      _catchUp();
      _resolveDestination();
    }
  }

  bool _probing = false;

  /// While offline: one small request to see whether TPM is reachable again.
  /// Going back online resumes the queued lookups.
  Future<void> _probe() async {
    if (_online || _probing) return;
    _probing = true;
    try {
      _cache.colors.addAll(await _api.colorNames(widget.session));
      _setOnline(true);
    } on SessionExpiredException catch (e) {
      if (!_expired && mounted) {
        _expired = true;
        _snack(e.message);
        await widget.onSignedOut();
      }
    } on OfflineException {
      // Still offline; the next check is in 30 s.
    } on TpmApiException {
      _setOnline(true); // TPM answered, so we're connected
    } finally {
      _probing = false;
    }
  }

  /// Looks up everything that was scanned offline (or failed), oldest first.
  Future<void> _catchUp() async {
    if (_catchingUp || !_online) return;
    _catchingUp = true;
    try {
      for (final b in List<String>.of(_store.barcodes)) {
        final l = _lookups[b];
        if (l == null || l.waiting || l.error != null) {
          await _lookup(b, quiet: true);
          if (!_online) break;
        }
      }
    } finally {
      _catchingUp = false;
    }
    final flagged = _store.barcodes.where((b) => _lookups[b]?.skipReason(_dest) != null).length;
    if (_online && flagged > 0 && mounted) _snack('Caught up — $flagged item(s) flagged');
  }

  int get _waitingCount => _store.barcodes.where((b) => _lookups[b]?.waiting ?? false).length;

  /// On-screen keyboard for the scan field. Off by default — scanners don't need it
  /// (keystroke scanners still type into the focused field); the keyboard button shows it.
  bool _typing = false;

  static const _keyboard = MethodChannel('scan_pull/keyboard');

  void _toggleKeyboard() {
    setState(() => _typing = !_typing);
    // The new keyboard type only applies once the field regains focus.
    _focus.unfocus();
    Future.delayed(const Duration(milliseconds: 50), _focus.requestFocus);
  }

  /// Unless the user asked to type, make sure no on-screen keyboard is up. Runs on
  /// focus and after each scan, with a second pass for keyboards that open late.
  void _hideKeyboard() {
    if (_typing) return;
    for (final ms in [0, 150, 400]) {
      Future.delayed(Duration(milliseconds: ms), () {
        if (_typing || !mounted) return;
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        _keyboard.invokeMethod<void>('hide').catchError((_) {});
      });
    }
  }

  /// Barcodes from terminal scan engines that send intent broadcasts instead of
  /// keystrokes (see MainActivity.kt).
  static const _scanner = EventChannel('scan_pull/scanner');
  StreamSubscription<dynamic>? _scans;

  /// Characters typed by a scanner in key-event mode while the field doesn't
  /// have focus; added on Enter.
  final _keyBuffer = StringBuffer();

  /// Scanner diagnostics: every broadcast and hardware key press received,
  /// newest last. Shown from the bug button.
  final _diag = <String>[];

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _focus.addListener(() {
      if (_focus.hasFocus) _hideKeyboard();
    });
    _hideKeyboard();
    // Losing the network flips straight to offline; a reconnect only prompts a check.
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      final connected = results.any((r) => r != ConnectivityResult.none);
      if (!connected) {
        _setOnline(false);
      } else if (!_online) {
        _probe();
      }
    });
    // Offline: check every 30 s whether TPM is back. Online: retry anything still queued.
    _retry = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_online) {
        _probe();
      } else if (_waitingCount > 0) {
        _catchUp();
      }
    });
    Future.wait([
      _store.load(),
      _cache.load(),
      Connectivity()
          .checkConnectivity()
          .then((r) {
            if (!r.any((c) => c != ConnectivityResult.none)) _online = false;
          })
          .catchError((_) {}),
    ]).then((_) {
      setState(() => _loaded = true);
      // Show last known details right away, then refresh them all from TPM.
      _locationsKnown = _cache.locations.isNotEmpty;
      _relookupAll(); // offline, this just marks them as waiting
      if (_online) _resolveDestination();
      _scans = _scanner.receiveBroadcastStream().listen(_onBroadcast);
      _log('Listening for scanner broadcasts and key presses');
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _scans?.cancel();
    _connectivity?.cancel();
    _retry?.cancel();
    _api.close();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _log(String line) {
    final t = TimeOfDay.now().format(context);
    _diag.add('$t  $line');
    if (_diag.length > 100) _diag.removeAt(0);
  }

  void _onBroadcast(dynamic data) {
    if (data is! Map) return;
    _log('Broadcast ${data['action']}\n  extras: ${data['extras']}');
    final barcode = data['barcode'];
    if (barcode is String) _add(barcode);
  }

  /// Scanners in key-event mode: the focused field handles its own typing;
  /// otherwise collect characters here and add the barcode on Enter.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    _log(
      'Key ${event.logicalKey.debugName} char=${jsonEncode(event.character)}'
      '${_focus.hasFocus ? ' (field has focus)' : ''}',
    );
    if (_focus.hasFocus) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final barcode = _keyBuffer.toString();
      _keyBuffer.clear();
      if (barcode.isNotEmpty) _add(barcode);
      return true;
    }
    final char = event.character;
    if (char != null && char.isNotEmpty && char != '\n' && char != '\r') {
      _keyBuffer.write(char);
      return true;
    }
    return false;
  }

  void _showDiagnostics() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Scanner diagnostics — scan a barcode, then reopen this. If nothing new appears, '
                'the scanner is not sending to this app.',
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final line in _diag.reversed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Adds a barcode from any source. Hardware scanners in keyboard mode type
  /// the barcode into the text field and press Enter, which lands here too.
  bool _add(String raw) {
    final barcode = raw.trim();
    if (barcode.isEmpty) return false;
    final added = _store.add(barcode);
    setState(() {});
    _hideKeyboard();
    if (added) {
      HapticFeedback.lightImpact();
      _lookup(barcode);
    } else {
      HapticFeedback.heavyImpact();
      _snack('$barcode is already in the list');
    }
    return added;
  }

  void _onSubmitted(String value) {
    _add(value);
    _input.clear();
    _focus.requestFocus();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  Future<void> _openCamera() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            CameraScanPage(onBarcode: _add, inList: _store.barcodes.contains, count: () => _store.barcodes.length),
      ),
    );
    setState(() {});
    _focus.requestFocus();
  }

  Future<void> _share() async {
    if (_store.barcodes.isEmpty) {
      _snack('Nothing to share yet');
      return;
    }
    final file = await _store.exportCsv();
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'text/csv')],
        subject: 'Scan Pull - ${_store.barcodes.length} barcodes',
      ),
    );
  }

  Future<void> _confirmClear() async {
    if (_store.barcodes.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear list?'),
        content: Text('Remove all ${_store.barcodes.length} barcodes. Share the CSV first if you need it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _store.clear();
        _lookups.clear();
      });
      _cache.save();
    }
    _focus.requestFocus();
  }

  /// Sends the pullable barcodes to the destination — TPM Scan Pull, or an IMS quick
  /// movement into a Scan Pull location — then shows the results. Flagged barcodes
  /// are skipped. Pulled barcodes leave the list; failed and skipped ones stay.
  Future<void> _submitScanPull() async {
    // Make sure the destination is current (locations may have been set up or removed).
    if (await _resolveDestination()) {
      _snack('Destination changed to ${_dest?.label ?? 'TPM Scan Pull'} — review the list, then submit');
      return;
    }
    if (!mounted) return;
    final dest = _dest;
    final all = List<String>.of(_store.barcodes);
    final skipped = {for (final b in all) b: ?_lookups[b]?.skipReason(_dest)};
    // Still loading or lookup failed: send anyway and let TPM decide.
    final barcodes = all.where((b) => !skipped.containsKey(b)).toList();
    if (barcodes.isEmpty) {
      _snack(all.isEmpty ? 'Scan some barcodes first' : 'Nothing to pull — see the flagged items');
      return;
    }
    final total = barcodes.fold<double>(0, (t, b) => t + (_lookups[b]?.details?.price ?? 0));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.session.env == BrijjEnv.production ? 'Submit Scan Pull — PRODUCTION?' : 'Submit Scan Pull?'),
        content: Text(
          '${barcodes.length} item(s), ${_money(total)}, will be '
          '${dest == null ? 'scan pulled in TPM' : 'moved to ${dest.label}'} — removed from TPM and POS for '
          '${widget.session.companyLabel}, recorded as ${widget.session.fullName}.'
          '${skipped.isEmpty ? '' : '\n\n${skipped.length} flagged item(s) will be skipped.'}'
          '\n\nThis cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: statusDanger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _submitting = true);
    final api = TpmApi(widget.session.env);
    try {
      final List<ScanPullResult> sent;
      if (dest == null) {
        sent = await api.scanPull(widget.session, barcodes);
      } else {
        // Every item needs its IMS record: look up any that weren't checked yet.
        final sources = <String, ImsSerial>{};
        for (final b in barcodes) {
          var l = _lookups[b];
          if (l == null || l.ims == null) {
            final ims = await api.imsFind(widget.session, b, dest.allWarehouseIds);
            l = l?.details == null ? Lookup.failed('Not checked', null, ims) : Lookup.found(l!.details!, ims);
            _lookups[b] = l;
          }
          final reason = l.skipReason(dest);
          final source = l.source(dest);
          if (reason == null && source != null) {
            sources[b] = source;
          } else {
            skipped[b] = reason ?? 'Not in IMS inventory';
          }
        }
        sent = sources.isEmpty ? [] : await api.moveToLocation(widget.session, dest, sources);
      }
      final results = [...sent, for (final e in skipped.entries) ScanPullResult(e.key, 'Skipped — ${e.value}')];
      await SessionStore.save(widget.session); // the access token may have been refreshed
      if (!mounted) return;
      final details = {for (final r in results) r.barcode: _lookups[r.barcode]?.details};
      setState(() {
        final pulled = results.where((r) => r.pulled).map((r) => r.barcode);
        _store.removeAll(pulled);
        pulled.forEach(_lookups.remove);
      });
      _cache.save();
      HapticFeedback.mediumImpact();
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ScanPullResultsPage(
            results: results,
            details: details,
            pulledBy: widget.session.fullName,
            destination: dest?.label ?? 'TPM Scan Pull',
          ),
        ),
      );
    } on OfflineException {
      _setOnline(false);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No connection'),
          content: const Text(
            'The connection dropped while submitting. Your list was kept. '
            'When you\'re back online, check TPM before submitting again — some items may '
            'already have been pulled.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } on SessionExpiredException catch (e) {
      // The list is saved on the device, so it's still there after signing back in.
      _snack(e.message);
      await widget.onSignedOut();
      return;
    } on TpmApiException catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Scan Pull not submitted'),
          content: Text(
            '$e\n\nYour list was kept. Nothing was confirmed as pulled — '
            'if the error came after sending, check ${dest == null ? 'TPM' : 'IMS movement orders'} '
            'before resubmitting.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } finally {
      api.close();
      if (mounted) setState(() => _submitting = false);
    }
    _focus.requestFocus();
  }

  /// Whether the company's Scan Pull locations have been loaded at least once.
  bool _locationsKnown = false;

  /// Chooses the destination: an IMS Scan Pull location when the company has one
  /// (the primary method), otherwise TPM Scan Pull. Keeps the user's pick when it
  /// still exists. Returns true if the destination changed.
  Future<bool> _resolveDestination() async {
    if (!_online) return false;
    try {
      final locations = await _api.scanPullLocations(widget.session);
      _cache.locations
        ..clear()
        ..addAll(locations);
      _locationsKnown = true;
    } on TpmApiException {
      // Offline: keep the last known list and destination.
      if (!mounted) return false;
      setState(() => _locationsKnown = _locationsKnown || _cache.locations.isNotEmpty);
      return false;
    }
    final current = _dest;
    final locations = _cache.locations;
    final next = locations.isEmpty
        ? null
        : locations.firstWhere((l) => l.id == current?.id, orElse: () => locations.first);
    final changed = next?.id != current?.id;
    if (!mounted) return changed;
    setState(() => _cache.destination = next);
    _cache.save();
    if (changed) _relookupAll();
    return changed;
  }

  /// A location destination needs to know where each item is in IMS.
  void _relookupAll() {
    for (final b in _store.barcodes) {
      _lookup(b, quiet: true);
    }
  }

  /// Picks between the company's IMS Scan Pull locations (only when there are several).
  Future<void> _chooseDestination() async {
    await _resolveDestination();
    final locations = _cache.locations;
    if (!mounted || locations.length < 2) {
      _focus.requestFocus();
      return;
    }
    final picked = await showModalBottomSheet<ScanPullLocation>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Pull to', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ),
            for (final l in locations)
              ListTile(
                leading: Icon(_dest?.id == l.id ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(l.label),
                subtitle: const Text('Items move here from this store\'s sales floor'),
                onTap: () => Navigator.pop(context, l),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked.id != _dest?.id && mounted) {
      setState(() => _cache.destination = picked);
      _cache.save();
      _relookupAll();
    }
    _focus.requestFocus();
  }

  Widget _destinationBar() {
    final dest = _dest;
    return Material(
      color: dest == null ? Colors.white : brijjGreenTint,
      child: ListTile(
        dense: true,
        leading: Icon(dest == null ? Icons.cloud_upload : Icons.place, color: dest == null ? brijjBlue : statusSuccess),
        title: Text(
          dest == null ? 'Pull to: TPM Scan Pull' : 'Pull to: ${dest.label}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        subtitle: dest == null
            ? Text(_locationsKnown ? 'No IMS Scan Pull location set up' : 'Checking IMS Scan Pull locations…')
            : const Text('From the sales floor only'),
        trailing: _cache.locations.length > 1
            ? TextButton(onPressed: _submitting ? null : _chooseDestination, child: const Text('Change'))
            : null,
        onTap: _submitting || _cache.locations.length < 2 ? null : _chooseDestination,
      ),
    );
  }

  Widget _summary(List<String> barcodes) {
    final ready = barcodes.where((b) => _lookups[b]?.skipReason(_dest) == null).toList();
    final flagged = barcodes.length - ready.length;
    final checking = barcodes.where((b) => _lookups[b]?.loading ?? true).length;
    final waiting = _waitingCount;
    final total = ready.fold<double>(0, (t, b) => t + (_lookups[b]?.details?.price ?? 0));
    return Container(
      width: double.infinity,
      color: brijjBlueTint,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        [
          '${ready.length} to pull · ${_money(total)}',
          if (flagged > 0) '$flagged flagged',
          if (checking > 0) 'checking $checking…',
          if (waiting > 0) '$waiting waiting',
        ].join('   ·   '),
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: flagged > 0 ? statusWarning : brijjInk),
      ),
    );
  }

  Widget _itemTile(int index, String barcode) {
    final l = _lookups[barcode] ?? const Lookup.checking();
    final d = l.details;
    final skip = l.skipReason(_dest);
    final Widget trailing;
    if (l.loading) {
      trailing = const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (l.waiting) {
      trailing = const Icon(Icons.cloud_off, color: brijjText);
    } else if (l.error != null) {
      trailing = IconButton(
        tooltip: 'Retry lookup',
        icon: const Icon(Icons.refresh, color: statusWarning),
        onPressed: () => _lookup(barcode),
      );
    } else if (skip != null) {
      trailing = const Icon(Icons.block, color: statusDanger);
    } else {
      trailing = const Icon(Icons.check_circle, color: statusSuccess);
    }
    final weekColor = _hexColor(d?.color);
    return ListTile(
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: weekColor ?? brijjBlueTint,
        child: Text(
          '${index + 1}',
          style: TextStyle(
            fontSize: 12,
            color: weekColor == null ? brijjBlue : (weekColor.computeLuminance() < 0.5 ? Colors.white : brijjInk),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(barcode, style: const TextStyle(fontFamily: 'monospace', fontSize: 18)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d != null)
            Text(
              _describe(d),
              style: const TextStyle(fontWeight: FontWeight.w600, color: brijjInk),
            ),
          if (d != null && _where(d).isNotEmpty) Text(_where(d)),
          if (d != null) _colorChip(d, _cache),
          if (_dest != null && l.ims != null && l.ims!.isNotEmpty)
            Text(
              'IMS: ${l.ims!.map((x) => x.locationName).toSet().join(', ')}',
              style: const TextStyle(color: brijjBlue),
            ),
          if (skip != null)
            Text(
              skip,
              style: const TextStyle(color: statusDanger, fontWeight: FontWeight.w600),
            ),
          if (l.error != null) Text('Lookup failed — tap ↻ to retry', style: const TextStyle(color: statusWarning)),
          if (l.loading) Text(d == null ? 'Looking up…' : 'Refreshing…'),
          if (l.waiting)
            Text(
              d == null ? 'Offline — will look up when back online' : 'Offline — last known details',
              style: const TextStyle(color: brijjText, fontStyle: FontStyle.italic),
            ),
        ],
      ),
      isThreeLine: d != null,
      trailing: trailing,
    );
  }

  Future<void> _showAccount() async {
    final session = widget.session;
    final count = _store.barcodes.length;
    final signOut = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: _accountTitle(session),
        content: Text(
          '${session.companyLabel}\n'
          '${count == 0 ? '' : '\nSigning out clears the $count scanned barcode(s) on this device.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (signOut != true) {
      _focus.requestFocus();
      return;
    }
    // The next person on this device must not pull this user's list under their own name.
    _store.clear();
    _lookups.clear();
    await LookupCache.clear();
    final api = TpmApi(session.env);
    await api.signOut(session);
    api.close();
    await widget.onSignedOut();
  }

  @override
  Widget build(BuildContext context) {
    final barcodes = _store.barcodes;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Scan Pull (${barcodes.length})'),
            Text(widget.session.fullName, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Account / sign out',
            icon: UserAvatar(name: widget.session.fullName),
            onPressed: _showAccount,
          ),
          IconButton(tooltip: 'Scanner diagnostics', icon: const Icon(Icons.bug_report), onPressed: _showDiagnostics),
          IconButton(tooltip: 'Clear', icon: const Icon(Icons.delete_sweep), onPressed: _confirmClear),
          IconButton(tooltip: 'Share CSV', icon: const Icon(Icons.share), onPressed: _share),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCamera,
        icon: const Icon(Icons.camera_alt),
        label: const Text('Camera'),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: _submitting || barcodes.isEmpty || !_online ? null : _submitScanPull,
            icon: _submitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_online ? Icons.cloud_upload : Icons.cloud_off),
            label: Text(
              _submitting
                  ? 'Submitting…'
                  : _online
                  ? 'Submit Scan Pull (${barcodes.length})'
                  : 'Offline — submit when back online',
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _input,
              focusNode: _focus,
              autofocus: true,
              keyboardType: _typing ? TextInputType.text : TextInputType.none,
              decoration: InputDecoration(
                labelText: 'Scan or type a barcode',
                prefixIcon: const Icon(Icons.qr_code_scanner),
                suffixIcon: IconButton(
                  tooltip: _typing ? 'Hide keyboard' : 'Type a barcode',
                  icon: Icon(_typing ? Icons.keyboard_hide : Icons.keyboard),
                  onPressed: _toggleKeyboard,
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: _onSubmitted,
            ),
          ),
          _destinationBar(),
          if (!_online)
            Container(
              width: double.infinity,
              color: brijjText,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Text(
                'Offline — keep scanning. Scans are saved and looked up when you\'re back online.',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          if (barcodes.isNotEmpty) _summary(barcodes),
          Expanded(
            child: !_loaded
                ? const Center(child: CircularProgressIndicator())
                : barcodes.isEmpty
                ? const Center(child: Text('No barcodes scanned yet'))
                : ListView.separated(
                    itemCount: barcodes.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      // Newest first.
                      final index = barcodes.length - 1 - i;
                      final barcode = barcodes[index];
                      return Dismissible(
                        key: ValueKey(barcode),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: statusDanger,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) {
                          setState(() {
                            _store.removeAt(index);
                            _lookups.remove(barcode);
                          });
                          _cache.save();
                          _snack('Removed $barcode');
                        },
                        child: _itemTile(index, barcode),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// What happened to each barcode in a submitted Scan Pull.
class ScanPullResultsPage extends StatelessWidget {
  const ScanPullResultsPage({
    super.key,
    required this.results,
    required this.details,
    required this.pulledBy,
    required this.destination,
  });

  /// Where items went, e.g. "TPM Scan Pull" or "Memphis / Scan Pull - Memphis".
  final String destination;

  final List<ScanPullResult> results;
  final Map<String, ItemDetails?> details;
  final String pulledBy;

  @override
  Widget build(BuildContext context) {
    final pulled = results.where((r) => r.pulled).length;
    final value = results.where((r) => r.pulled).fold<double>(0, (t, r) => t + (details[r.barcode]?.price ?? 0));
    final failed = results.length - pulled;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Pull results')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: failed == 0 ? brijjGreenTint : statusWarningTint,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text('$pulled of ${results.length} pulled', style: Theme.of(context).textTheme.headlineSmall),
                Text('${_money(value)} · by $pulledBy'),
                Text('to $destination'),
                if (failed > 0)
                  Text(
                    '$failed failed — they are still in your list',
                    style: const TextStyle(color: statusDanger, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: results.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                // Failures first, so they aren't missed.
                final sorted = [...results.where((r) => !r.pulled), ...results.where((r) => r.pulled)];
                final r = sorted[i];
                return ListTile(
                  leading: Icon(
                    r.pulled ? Icons.check_circle : Icons.error,
                    color: r.pulled ? statusSuccess : statusDanger,
                  ),
                  title: Text(r.barcode, style: const TextStyle(fontFamily: 'monospace', fontSize: 18)),
                  subtitle: Text(
                    [
                      if (details[r.barcode] case final d?) _describe(d),
                      r.error ?? (r.note == null ? 'Pulled' : 'Pulled · ${r.note}'),
                    ].join('\n'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: () => Navigator.pop(context),
            child: const Text('Done', style: TextStyle(fontSize: 18)),
          ),
        ),
      ),
    );
  }
}

/// Camera scanning with a crosshair. Only a barcode that sits entirely inside
/// the scan box is captured, and only when it's the only one in the box — so a
/// sheet of tags isn't swept up at once. After each capture the camera pauses
/// briefly so the user can move to the next tag.
class CameraScanPage extends StatefulWidget {
  const CameraScanPage({super.key, required this.onBarcode, required this.inList, required this.count});

  /// Adds a new barcode to the list.
  final bool Function(String barcode) onBarcode;
  final bool Function(String barcode) inList;
  final int Function() count;

  @override
  State<CameraScanPage> createState() => _CameraScanPageState();
}

class _CameraScanPageState extends State<CameraScanPage> {
  static const _pause = Duration(milliseconds: 1000);

  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.normal);

  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// The barcode just added — it's still in view after the pause and must not
  /// then be flagged as a duplicate.
  String? _justAdded;
  Timer? _forgetJustAdded;

  /// The duplicate currently being flagged, so the warning vibrates once rather
  /// than on every frame.
  String? _flagged;
  Timer? _reset;

  String? _last;
  String _message = 'Center one barcode in the box';
  Color _boxColor = Colors.white;

  @override
  void dispose() {
    _reset?.cancel();
    _forgetJustAdded?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Returns the box to white once nothing has been detected for [after].
  void _resetBoxAfter(Duration after) {
    _reset?.cancel();
    _reset = Timer(after, () {
      if (!mounted) return;
      setState(() {
        _boxColor = Colors.white;
        _flagged = null;
      });
    });
  }

  /// Once the just-added barcode has been out of the box for [after], seeing it
  /// again is a duplicate.
  void _forgetJustAddedAfter(Duration after) {
    _forgetJustAdded?.cancel();
    _forgetJustAdded = Timer(after, () => _justAdded = null);
  }

  void _onDetect(BarcodeCapture capture) {
    if (DateTime.now().isBefore(_pausedUntil)) return;

    final values = capture.barcodes.map((b) => b.rawValue).whereType<String>().where((v) => v.isNotEmpty).toSet();
    if (values.length > 1) {
      setState(() => _message = 'More than one barcode in the box — center just one');
      return;
    }
    if (values.isEmpty) return;

    final value = values.first;
    if (value == _justAdded) {
      _forgetJustAddedAfter(const Duration(milliseconds: 700));
      return;
    }
    _justAdded = null;

    // Already in the list: red box for as long as it stays in view.
    if (widget.inList(value)) {
      if (_flagged != value) {
        _flagged = value;
        HapticFeedback.heavyImpact();
      }
      setState(() {
        _message = '$value is already in the list';
        _boxColor = statusDanger;
      });
      _resetBoxAfter(const Duration(milliseconds: 700));
      return;
    }

    widget.onBarcode(value);
    _justAdded = value;
    _forgetJustAddedAfter(_pause + const Duration(milliseconds: 700));
    _flagged = null;
    _pausedUntil = DateTime.now().add(_pause);
    setState(() {
      _last = value;
      _message = 'Added $value';
      _boxColor = brijjGreen;
    });
    _resetBoxAfter(_pause);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Camera scan (${widget.count()})'),
        actions: [
          IconButton(tooltip: 'Torch', icon: const Icon(Icons.flashlight_on), onPressed: _controller.toggleTorch),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Wide, short box sized for one tag barcode.
          final size = constraints.biggest;
          final scanWindow = Rect.fromCenter(
            center: size.center(Offset.zero),
            width: size.width * 0.8,
            height: size.width * 0.35,
          );
          return Stack(
            children: [
              MobileScanner(controller: _controller, scanWindow: scanWindow, onDetect: _onDetect),
              ScanWindowOverlay(
                controller: _controller,
                scanWindow: scanWindow,
                borderColor: _boxColor,
                borderWidth: 4,
                borderRadius: BorderRadius.circular(12),
              ),
              Positioned.fromRect(
                rect: scanWindow,
                child: IgnorePointer(child: CustomPaint(painter: _CrosshairPainter(_boxColor))),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  color: Colors.black54,
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _last == null ? _message : '$_message\nLast: $_last',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Aiming line across the scan box with a short vertical tick at the center.
class _CrosshairPainter extends CustomPainter {
  _CrosshairPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 2;
    final c = size.center(Offset.zero);
    canvas.drawLine(Offset(12, c.dy), Offset(size.width - 12, c.dy), paint);
    canvas.drawLine(Offset(c.dx, c.dy - 18), Offset(c.dx, c.dy + 18), paint);
  }

  @override
  bool shouldRepaint(_CrosshairPainter old) => old.color != color;
}
