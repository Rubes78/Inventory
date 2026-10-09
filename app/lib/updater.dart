import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';

/// Over-the-air updates for the sideloaded APK.
///
/// Each release is published (by `publish.sh`) to [baseUrl] as `ScanPull-<version>.apk`
/// plus `version.json` ({version, build, apk, size, notes}). The app compares `build` with
/// its own versionCode, downloads the APK into cache/updates and opens Android's package
/// installer; the user confirms with one tap. Android doesn't allow silent installs for an
/// ordinary app — that needs MDM / device owner.
class Updater {
  static const baseUrl = 'https://apps.whiskeredwoodworker.com/brijj-inventory/';
  static const _channel = MethodChannel('scan_pull/update');

  /// The update found by the last [check], shared by every screen showing an [UpdateCard].
  static final available = ValueNotifier<UpdateInfo?>(null);

  static DateTime? _lastCheck;

  /// Looks for a newer build; quiet on any failure (offline, server down…).
  /// Rate-limited to once every 10 minutes unless [force].
  static Future<UpdateInfo?> check({bool force = false}) async {
    if (!force && _lastCheck != null && DateTime.now().difference(_lastCheck!) < const Duration(minutes: 10)) {
      return available.value;
    }
    _lastCheck = DateTime.now();
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await http.getUrl(Uri.parse('${baseUrl}version.json')).timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return available.value;
      final text = await res.transform(utf8.decoder).join();
      final info = UpdateInfo.fromJson(jsonDecode(text) as Map<String, dynamic>);
      final mine = await _channel.invokeMapMethod<String, dynamic>('version');
      final current = (mine?['code'] as num?)?.toInt() ?? 0;
      available.value = info.build > current ? info : null;
    } catch (_) {
      // Leave whatever we knew; the next check retries.
    } finally {
      http.close(force: true);
    }
    return available.value;
  }

  static Future<String> currentVersion() async {
    try {
      final mine = await _channel.invokeMapMethod<String, dynamic>('version');
      return '${mine?['name'] ?? '?'} (${mine?['code'] ?? '?'})';
    } catch (_) {
      return '?';
    }
  }

  static Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;

  static Future<void> openInstallSettings() => _channel.invokeMethod('openInstallSettings');

  /// Downloads [info]'s APK, reporting progress 0..1, and returns the file.
  static Future<File> download(UpdateInfo info, void Function(double) onProgress) async {
    final dir = await _channel.invokeMethod<String>('dir');
    final file = File('$dir/${info.apk}');
    final part = File('${file.path}.part');
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final res = await (await http.getUrl(Uri.parse('$baseUrl${info.apk}'))).close();
      if (res.statusCode != 200) throw UpdateException('Download failed (HTTP ${res.statusCode}).');
      final total = res.contentLength > 0 ? res.contentLength : info.size;
      final sink = part.openWrite();
      var got = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress(got / total);
      }
      await sink.close();
      if (info.size > 0 && got != info.size) {
        throw UpdateException('Download incomplete ($got of ${info.size} bytes). Try again.');
      }
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
      // Old downloads aren't needed once this one is complete.
      for (final f in Directory(dir!).listSync()) {
        if (f is File && f.path != file.path) f.deleteSync();
      }
      return file;
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw UpdateException('Download timed out. Check the connection and try again.');
    } on SocketException {
      throw UpdateException('No connection to the update server.');
    } finally {
      http.close(force: true);
    }
  }

  /// Opens Android's installer for [apk]; the app restarts as the new version.
  static Future<void> install(File apk) => _channel.invokeMethod('install', {'path': apk.path});
}

class UpdateInfo {
  UpdateInfo({required this.version, required this.build, required this.apk, this.size = 0, this.notes = ''});

  final String version;
  final int build;
  final String apk;
  final int size;
  final String notes;

  static UpdateInfo fromJson(Map<String, dynamic> j) => UpdateInfo(
    version: '${j['version']}',
    build: (j['build'] as num).toInt(),
    apk: '${j['apk']}',
    size: (j['size'] as num?)?.toInt() ?? 0,
    notes: '${j['notes'] ?? ''}',
  );
}

class UpdateException implements Exception {
  UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// "Update available" card with an Install button; hidden when there's no update.
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  double? _progress;
  String? _error;

  Future<void> _install(UpdateInfo info) async {
    setState(() => _error = null);
    try {
      if (!await Updater.canInstall()) {
        if (!mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Allow app updates'),
            content: const Text(
              'Android needs permission for Brijj Inventory to install its own updates '
              '(one time only).\n\nOn the next screen turn on "Allow from this source", come back, '
              'and tap Install again.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open settings')),
            ],
          ),
        );
        if (go == true) await Updater.openInstallSettings();
        return;
      }
      setState(() => _progress = 0);
      final apk = await Updater.download(info, (p) {
        if (mounted) setState(() => _progress = p);
      });
      await Updater.install(apk);
    } on UpdateException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = 'Could not install: ${e.message}');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: Updater.available,
      builder: (context, info, _) {
        if (info == null) return const SizedBox.shrink();
        final busy = _progress != null;
        return Card(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.system_update, size: 32, color: brijjBlue),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Update available — v${info.version}',
                        style: const TextStyle(
                          fontFamily: headingFont,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: brijjInk,
                        ),
                      ),
                    ),
                  ],
                ),
                if (info.notes.isNotEmpty) ...[const SizedBox(height: 8), Text(info.notes)],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 12),
                if (busy)
                  LinearProgressIndicator(value: _progress == 0 ? null : _progress, minHeight: 8)
                else
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => _install(info),
                    icon: const Icon(Icons.download),
                    label: const Text('Install update'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
