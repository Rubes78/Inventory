import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'brand.dart';
import 'tpm_api.dart';

/// An IMS web page inside the app, already signed in — for work the app doesn't do
/// natively yet. The IMS web app keeps its sign-in in the accessToken/refreshToken
/// cookies and its warehouse in localStorage (imsSelectedWarehouseId), so both are
/// set to match the app before the page is used.
class ImsWebPage extends StatefulWidget {
  const ImsWebPage({super.key, required this.session, required this.path, required this.title, this.warehouseId});

  final BrijjSession session;

  /// e.g. "/purchase?Id=123".
  final String path;
  final String title;
  final int? warehouseId;

  @override
  State<ImsWebPage> createState() => _ImsWebPageState();
}

class _ImsWebPageState extends State<ImsWebPage> {
  WebViewController? _controller;
  bool _loading = true;
  bool _warehouseSet = false;
  String? _error;

  Uri get _url => Uri.parse('${widget.session.env.imsWeb}${widget.path}');

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    final api = TpmApi(widget.session.env);
    try {
      final token = await api.freshToken(widget.session);
      final host = _url.host;
      final cookies = WebViewCookieManager();
      for (final c in {'accessToken': token, 'refreshToken': widget.session.refreshToken}.entries) {
        await cookies.setCookie(WebViewCookie(name: c.key, value: c.value, domain: host, path: '/'));
      }
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.white)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (_) {
              if (mounted) setState(() => _loading = true);
            },
            onPageFinished: _onPageFinished,
            onWebResourceError: (e) {
              if (e.isForMainFrame == true && mounted) setState(() => _error = e.description);
            },
          ),
        );
      await controller.loadRequest(_url);
      if (mounted) setState(() => _controller = controller);
    } on TpmApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e is OfflineException ? 'Offline — IMS pages need a connection.' : e.message;
          _loading = false;
        });
      }
    } finally {
      api.close();
    }
  }

  Future<void> _onPageFinished(String url) async {
    final controller = _controller;
    if (!mounted || controller == null) return;
    if (url.contains('/shared/login')) {
      setState(() {
        _error = 'IMS asked to sign in again. Close this page and try once more; if it keeps happening, '
            'use the IMS web app for this task.';
        _loading = false;
      });
      return;
    }
    // Match the IMS web app's warehouse to the app's, then reload once so it applies.
    final wh = widget.warehouseId;
    if (wh != null && !_warehouseSet) {
      _warehouseSet = true;
      await controller.runJavaScript(
        "localStorage.setItem('imsSavePreference','false');localStorage.setItem('imsSelectedWarehouseId','$wh');",
      );
      await controller.loadRequest(_url);
      return;
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (controller != null && await controller.canGoBack()) {
          await controller.goBack();
        } else if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(tooltip: 'Reload', onPressed: controller == null ? null : () => controller.reload(), icon: const Icon(Icons.refresh)),
            IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
          ],
          bottom: _loading
              ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator(minHeight: 3))
              : null,
        ),
        body: _error != null
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ListTile(leading: const Icon(Icons.error, color: statusDanger), title: Text(_error!)),
                  FilledButton(onPressed: _open, child: const Text('Try again')),
                ],
              )
            : controller == null
            ? const Center(child: CircularProgressIndicator())
            : WebViewWidget(controller: controller),
      ),
    );
  }
}
