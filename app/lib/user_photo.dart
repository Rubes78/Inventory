import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'brand.dart';
import 'tpm_api.dart';

/// The signed-in user's Brijj profile picture, kept on the device (`user_photo.img`) so it
/// shows offline and instantly on launch. Refreshed from company-api on every launch/sign-in;
/// deleted on sign-out.
class UserPhoto {
  static final bytes = ValueNotifier<Uint8List?>(null);

  /// The session the picture belongs to; a download finishing after sign-out is dropped.
  static String? _owner;

  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/user_photo.img');

  /// Shows the cached picture, then fetches the current one. Quiet on any failure.
  static Future<void> load(BrijjSession session) async {
    _owner = session.sessionId;
    try {
      final f = await _file();
      if (bytes.value == null && await f.exists()) bytes.value = await f.readAsBytes();
    } catch (_) {}
    final api = TpmApi(session.env);
    try {
      final url = await api.profilePhotoUrl(session);
      if (_owner != session.sessionId) return;
      if (url == null) {
        // The user removed their picture: show initials.
        await clear();
        return;
      }
      final data = await api.download(url);
      if (data == null || data.isEmpty) return;
      final b = Uint8List.fromList(data);
      // Only keep it if Flutter can decode it.
      (await ui.instantiateImageCodec(b)).dispose();
      if (_owner != session.sessionId) return;
      bytes.value = b;
      await (await _file()).writeAsBytes(b);
    } catch (_) {
      // Offline or not decodable: keep what we have.
    } finally {
      api.close();
    }
  }

  static Future<void> clear() async {
    _owner = null;
    bytes.value = null;
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// The user's picture in a circle, or their initials on Brijj blue when there's none.
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.name, this.radius = 18});

  final String name;
  final double radius;

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first[0];
    final last = parts.length > 1 ? parts.last[0] : '';
    return (first + last).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Uint8List?>(
      valueListenable: UserPhoto.bytes,
      builder: (context, photo, _) => CircleAvatar(
        radius: radius,
        backgroundColor: brijjBlue,
        foregroundImage: photo == null ? null : MemoryImage(photo),
        onForegroundImageError: photo == null ? null : (_, _) {},
        child: Text(
          initials(name),
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: radius * 0.8),
        ),
      ),
    );
  }
}
