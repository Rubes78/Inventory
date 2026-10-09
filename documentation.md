# ScanPull — documentation

## What it does

1. Open **Scan Pull**. The "Scan or type a barcode" field has focus.
2. Pull the terminal's scan trigger — the barcode is added to the list (newest on top) and the field
   clears for the next scan. Typing a barcode and pressing Enter does the same.
3. Or tap **Camera** to scan with the camera. Line up one tag's barcode inside the box, on the
   crosshair. It's captured only when it's fully inside the box and the only barcode there; the box
   flashes green and the camera pauses ~1 s so you can move to the next tag. A barcode already in
   the list turns the box and crosshair **red** (one strong vibration) for as long as it's in the box. Two barcodes in the box → nothing is captured until only one is. Torch button in the
   top bar. Back returns to the list.
4. A barcode already in the list is not added again — the device vibrates and says so.
5. Swipe a row left to remove it.
6. Tap **Share** → pick Google Drive / Gmail / Nearby Share etc. The file is
   `scanpull_YYYYMMDD_HHMMSS.csv`, one barcode per line.
7. Tap **Clear** (confirm) to start a new list. The list is kept until then, even if the app is closed.

## Design decisions

| Decision | Why |
|---|---|
| Keyboard-wedge input instead of vendor SDKs | Works on most Zebra / Honeywell / Sunmi terminals out of the box; no per-vendor code for a POC |
| Camera via `mobile_scanner` | Fallback for phones / terminals without a scan engine |
| Camera crosshair box, one barcode at a time, 1 s pause (v1.1.0) | v1 grabbed every tag on a sheet at once. `scanWindow` only reports barcodes fully inside the box; the app rejects frames with more than one. "Nearest the center" was rejected because barcode corner and frame-size coordinates can be in different orientations per device |
| Barcode-only CSV, no header | Chosen by the user; simplest to paste or import |
| Duplicates rejected | A barcode can only be pulled once, so repeats are scan mistakes |
| Share sheet, not Drive API | No Google Cloud project / OAuth needed; user picks Drive, email, etc. |
| Saved after every scan | A dropped or closed device doesn't lose a half-built pull |

## Installing on a device

1. The latest build is `release/ScanPull.apk`. After a rebuild (see `CLAUDE.md`), copy
   `app/build/app/outputs/flutter-apk/app-release.apk` over it.
2. Get the APK onto the device.
3. Open it on the device and allow "Install unknown apps" for whatever app opened it.
4. Grant camera permission the first time Camera is used.

## Terminal scanner setup

Since v1.3.0 the app takes scans two ways, so either scanner output mode works:

1. **Intent broadcast** (no focus needed — preferred). `MainActivity.kt` listens for:
   - CipherLab `com.cipherlab.barcodebaseapi.PASS_DATA` (extra `Decoder_Data`)
   - Urovo/iData `android.intent.ACTION_DECODE_DATA`, `com.android.server.scannerservice.broadcast`
   - Newland `nlscan.action.SCANNER_RESULT`, Sunmi `com.sunmi.scanner.ACTION_DATA_CODE_RECEIVED`
   - Our own `com.brijjworks.scan_pull.SCAN` (extra `data`) — set this as the custom intent action
     on any scanner whose intent output is configurable (Zebra DataWedge: Intent output, delivery
     Broadcast; ReaderConfig on CipherLab likewise).
   If the extra key isn't one we know, the first text extra is used.
2. **Keyboard / keystroke** into the focused field — needs an **Enter (CR/LF) suffix**:

CipherLab (added after the first device test, 2026-10-08 — the gun's scans didn't reach the app):
ReaderConfig app → Data Output. Either set output to **Intent** (default CipherLab action above), or
keep **Keyboard Emulation** and add an Enter suffix.

Keyboard-mode settings on other brands:
- Zebra: DataWedge → profile for the app (or Profile0) → Keystroke output on, "Send ENTER key" on.
- Honeywell: Settings → Scan Settings → Data Processing → Wedge method Keyboard, suffix Enter.
- Sunmi: Scanner settings → Output mode "Simulate keystroke" / "Keyboard", add Enter.

If scans land without a new row, the Enter suffix is missing.

## Open items

- How the CSV gets into TPM/Counterpoint — TPM Scan Pull has no file upload today.
- Vendor scanner intents (e.g. DataWedge broadcast) if keyboard wedge proves flaky.
- Proper release signing key if this goes beyond a POC.
