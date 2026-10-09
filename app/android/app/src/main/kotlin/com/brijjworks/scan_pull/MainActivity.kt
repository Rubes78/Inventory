package com.brijjworks.scan_pull

import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import com.cipherlab.barcode.GeneralString
import com.cipherlab.barcode.ReaderManager
import com.cipherlab.barcode.decoder.KeyboardEmulationType
import com.cipherlab.barcode.decoderparams.ReaderOutputConfiguration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.view.inputmethod.InputMethodManager

/**
 * Forwards scan broadcasts from terminal scan engines (which send intents rather than
 * keystrokes) to Flutter on the "scan_pull/scanner" event channel, as
 * {action, extras, barcode} maps.
 *
 * On CipherLab terminals (e.g. RS36) the scanner's default output is the CipherLab input
 * method, which never reaches this app. While the app is in the foreground it uses the
 * CipherLab API to turn keyboard emulation off, so scans arrive as PASS_DATA_2_APP
 * broadcasts; the previous setting is restored when the app goes to the background.
 *
 * Some terminals (e.g. Landi M20) put scans on the clipboard instead. While the app is in
 * the foreground, anything that looks like a barcode landing on the clipboard is taken as a
 * scan and the clipboard is cleared.
 */
class MainActivity : FlutterActivity() {
    companion object {
        /** Broadcast actions used by common Android terminals' scan services. */
        private val SCAN_ACTIONS = listOf(
            "com.brijjworks.scan_pull.SCAN",                 // our own — for any scanner with configurable intent output (e.g. Zebra DataWedge)
            GeneralString.Intent_PASS_TO_APP,                // CipherLab (com.cipherlab.barcodebaseapi.PASS_DATA_2_APP)
            "android.intent.ACTION_DECODE_DATA",             // Urovo, iData
            "com.android.server.scannerservice.broadcast",   // Urovo / generic
            "nlscan.action.SCANNER_RESULT",                  // Newland
            "com.sunmi.scanner.ACTION_DATA_CODE_RECEIVED",   // Sunmi
        )

        /** Extra keys those services put the barcode text in, most specific first. */
        private val DATA_KEYS = listOf(
            "Decoder_Data",                        // CipherLab
            "com.symbol.datawedge.data_string",    // Zebra DataWedge
            "barcode_string",                      // Urovo, iData
            "scannerdata",
            "SCAN_BARCODE1",                       // Newland
            "data",                                // Sunmi, our own action
        )

        fun barcodeFrom(intent: Intent): String? {
            val extras = intent.extras ?: return null
            for (key in DATA_KEYS) {
                when (val value = extras.get(key)) {
                    is String -> if (value.isNotBlank()) return value
                    is ByteArray -> if (value.isNotEmpty()) return String(value)
                }
            }
            // Unknown vendor key: take the first non-blank string extra.
            return extras.keySet().firstNotNullOfOrNull { key ->
                (extras.get(key) as? String)?.takeIf { it.isNotBlank() }
            }
        }
    }

    private var receiver: BroadcastReceiver? = null
    private var events: EventChannel.EventSink? = null

    // ── CipherLab scanner output ──────────────────────────────────────────
    private var cipherLab: ReaderManager? = null
    private var cipherLabConnected = false
    /** Keyboard emulation as it was before this app changed it; restored in onPause. */
    private var originalEmulation: KeyboardEmulationType? = null

    private val cipherLabReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            cipherLabConnected = true
            sendToApp(intent)
            routeScansToApp()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Register before InitInstance: the service announces itself with SERVICE_CONNECTED.
        val filter = IntentFilter(GeneralString.Intent_READERSERVICE_CONNECTED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(cipherLabReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(cipherLabReceiver, filter)
        }
        // Not a CipherLab device (no scan service) -> the API just never connects.
        cipherLab = try { ReaderManager.InitInstance(this) } catch (e: Throwable) { null }
    }

    override fun onResume() {
        super.onResume()
        if (cipherLabConnected) routeScansToApp()
        clipboard.addPrimaryClipChangedListener(clipListener)
    }

    override fun onPause() {
        clipboard.removePrimaryClipChangedListener(clipListener)
        restoreScannerOutput()
        super.onPause()
    }

    // ── Clipboard scanner output ─────────────────────────────────────────
    private val clipboard by lazy { getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager }

    /** One line, no spaces, not too long — so copied text (e.g. from diagnostics) isn't taken as a scan. */
    private val barcodePattern = Regex("^\\S{1,64}$")

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        val text = try {
            clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()?.trim()
        } catch (e: Throwable) {
            null
        }
        if (text.isNullOrEmpty()) return@OnPrimaryClipChangedListener
        if (!barcodePattern.matches(text)) {
            log("Clipboard: ignored (not a barcode): ${text.take(40)}")
            return@OnPrimaryClipChangedListener
        }
        events?.success(mapOf(
            "action" to "clipboard",
            "extras" to mapOf("text" to text),
            "barcode" to text,
        ))
        // Don't leave scans on the clipboard. (Clearing fires the listener again with no text.)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try { clipboard.clearPrimaryClip() } catch (e: Throwable) {}
        }
    }

    private fun routeScansToApp() {
        val reader = cipherLab ?: return
        try {
            val settings = ReaderOutputConfiguration()
            reader.Get_ReaderOutputConfiguration(settings)
            if (settings.enableKeyboardEmulation == KeyboardEmulationType.None) return
            originalEmulation = settings.enableKeyboardEmulation
            settings.enableKeyboardEmulation = KeyboardEmulationType.None
            reader.Set_ReaderOutputConfiguration(settings)
            log("CipherLab: scanner output switched to this app (was ${originalEmulation})")
        } catch (e: Throwable) {
            log("CipherLab: could not change scanner output: $e")
        }
    }

    private fun restoreScannerOutput() {
        val reader = cipherLab ?: return
        val original = originalEmulation ?: return
        try {
            val settings = ReaderOutputConfiguration()
            reader.Get_ReaderOutputConfiguration(settings)
            settings.enableKeyboardEmulation = original
            reader.Set_ReaderOutputConfiguration(settings)
            originalEmulation = null
        } catch (e: Throwable) {
            log("CipherLab: could not restore scanner output: $e")
        }
    }

    /** A line in the app's scanner diagnostics. */
    private fun log(message: String) {
        events?.success(mapOf("action" to message, "extras" to emptyMap<String, String>(), "barcode" to null))
    }

    private fun sendToApp(intent: Intent) {
        // Send the whole broadcast so the app's diagnostics can show it.
        val extras = intent.extras
        events?.success(mapOf(
            "action" to intent.action,
            "extras" to (extras?.keySet()?.associateWith { "${extras.get(it)}" } ?: emptyMap()),
            "barcode" to barcodeFrom(intent)?.trim(),
        ))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Hides the on-screen keyboard outright — some terminals' keyboards (Landi M20) ignore
        // Flutter's "no keyboard" input type for the focused scan field.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "scan_pull/keyboard").setMethodCallHandler { call, result ->
            if (call.method == "hide") {
                val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                imm.hideSoftInputFromWindow(window.decorView.windowToken, 0)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        // Self-update: the app downloads a newer APK into cache/updates and hands it to
        // Android's package installer (the user confirms). See lib/updater.dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "scan_pull/update").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "version" -> {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
                                   else @Suppress("DEPRECATION") info.versionCode.toLong()
                        result.success(mapOf("code" to code, "name" to info.versionName))
                    }
                    "dir" -> result.success(File(cacheDir, "updates").apply { mkdirs() }.absolutePath)
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls())
                    "openInstallSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")))
                        }
                        result.success(null)
                    }
                    "install" -> {
                        val apk = File(call.argument<String>("path")!!)
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
                        startActivity(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        })
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("update", e.toString(), null)
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "scan_pull/scanner").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    events = sink
                    if (cipherLabConnected) log("CipherLab scan service connected")
                    val scanReceiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent) = sendToApp(intent)
                    }
                    val filter = IntentFilter().apply { SCAN_ACTIONS.forEach { addAction(it) } }
                    // Scan services are other apps, so the receiver must be exported on Android 13+.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(scanReceiver, filter, Context.RECEIVER_EXPORTED)
                    } else {
                        registerReceiver(scanReceiver, filter)
                    }
                    receiver = scanReceiver
                }

                override fun onCancel(arguments: Any?) {
                    receiver?.let { unregisterReceiver(it) }
                    receiver = null
                    events = null
                }
            }
        )
    }

    override fun onDestroy() {
        receiver?.let { unregisterReceiver(it) }
        receiver = null
        unregisterReceiver(cipherLabReceiver)
        restoreScannerOutput()
        try { cipherLab?.Release() } catch (e: Throwable) {}
        cipherLab = null
        super.onDestroy()
    }
}
