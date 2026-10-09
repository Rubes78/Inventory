import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A scan field for any screen: takes keystroke scanners (typed + Enter) and
/// broadcast/clipboard scanners (MainActivity's `scan_pull/scanner` channel), and
/// keeps the on-screen keyboard down unless [allowTyping] is on.
class ScanInput extends StatefulWidget {
  const ScanInput({super.key, required this.onScan, this.label = 'Scan a barcode', this.enabled = true});

  final void Function(String barcode) onScan;
  final String label;
  final bool enabled;

  @override
  State<ScanInput> createState() => ScanInputState();
}

class ScanInputState extends State<ScanInput> {
  static const _scanner = EventChannel('scan_pull/scanner');
  static const _keyboard = MethodChannel('scan_pull/keyboard');

  final _input = TextEditingController();
  final _focus = FocusNode();
  StreamSubscription<dynamic>? _scans;
  bool _typing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) _hideKeyboard();
    });
    _scans = _scanner.receiveBroadcastStream().listen((data) {
      if (!widget.enabled) return;
      final b = data is Map ? data['barcode'] : null;
      if (b is String && b.trim().isNotEmpty) widget.onScan(b.trim());
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _scans?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Puts the cursor back in the field (after a dialog, say).
  void refocus() => _focus.requestFocus();

  void _hideKeyboard() {
    if (_typing) return;
    for (final ms in [0, 150, 400]) {
      Future.delayed(Duration(milliseconds: ms), () {
        if (!mounted || _typing) return;
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        _keyboard.invokeMethod<void>('hide').catchError((_) {});
      });
    }
  }

  void _toggleTyping() {
    setState(() => _typing = !_typing);
    _focus.unfocus();
    Future.delayed(const Duration(milliseconds: 50), _focus.requestFocus);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _input,
      focusNode: _focus,
      autofocus: true,
      enabled: widget.enabled,
      keyboardType: _typing ? TextInputType.text : TextInputType.none,
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: const Icon(Icons.qr_code_scanner),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _typing ? 'Hide keyboard' : 'Type instead',
          icon: Icon(_typing ? Icons.keyboard_hide : Icons.keyboard),
          onPressed: widget.enabled ? _toggleTyping : null,
        ),
      ),
      onSubmitted: (v) {
        final b = v.trim();
        _input.clear();
        _focus.requestFocus();
        if (b.isNotEmpty) widget.onScan(b);
      },
    );
  }
}
