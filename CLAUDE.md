# ScanPull — Android barcode list app (proof of concept)

Flutter app for Android terminals/phones: scan barcodes into a list, then share the list as a CSV
(Google Drive, Gmail, Nearby Share… via the Android share sheet). Intended as the front end for TPM
Scan Pull — collect barcodes on the floor, then load them into the system.

## Scope (POC decisions, 2026-10-07)

- **Scanning:** hardware scanner via intent broadcast (`MainActivity.kt`, since v1.3.0) or
  keyboard-wedge (types the barcode + Enter into the focused field), plus camera scanning
  (`mobile_scanner`). No vendor SDKs; Honeywell's intent API needs a claim call and isn't covered.
  The user's test terminal is a **CipherLab** Android device with a scan gun.
- **CSV:** barcode only — one barcode per line, no header, CRLF line endings. Duplicates are rejected
  in the app (vibrate + message), so the CSV never has repeats.
- **Export:** Android share sheet (`share_plus`). No Google sign-in / Drive API.
- **Persistence:** list saved to `scans.txt` in app documents after every change; survives app close.
  Cleared only by the Clear button (with confirm).
- TPM Scan Pull has no CSV upload today (barcodes are scanned/typed into Production > Scan Pulls >
  Search Barcode), so how the CSV gets into the system is still open.

## Status (2026-10-07)

- v1.0.0 accepted by the user as the initial POC (2026-10-08). Their feedback: camera swept up every
  tag on a sheet at once.
- v1.1.0 (2026-10-08) in `release/ScanPull.apk`: camera has a crosshair scan box — captures only a
  barcode fully inside the box, only when it's the sole one there, then pauses 1 s.
- v1.2.0 (2026-10-08): user noticed no feedback for already-scanned barcodes → box/crosshair turn red
  (with one heavy vibration) while a duplicate is in the box. The just-added barcode is exempt until
  it has been out of the box for 0.7 s.
- v1.3.0 (2026-10-08): on the user's **CipherLab** terminal the scan gun's barcodes never reached the
  app (keyboard-wedge only). Added intent-broadcast input: `MainActivity.kt` receiver → EventChannel
  `scan_pull/scanner` → `_add`. Covers CipherLab, Urovo/iData, Newland, Sunmi and our own action
  `com.brijjworks.scan_pull.SCAN`.
- v1.3.0 on the **RS36**: scanner beeps, nothing reaches the app (neither field nor broadcast).
- v1.4.0 (2026-10-08): bug button → scanner diagnostics log (every broadcast with action + extras,
  every hardware key press); key-event scans are captured even when the field isn't focused.
  Awaiting the user's diagnostics + ReaderConfig output settings from the RS36.
- 2026-10-08: `scan_pull.py` sends the app's CSV to TPM Scan Pull via API — **staging only**
  (WHISKERS API user → company-api SignIn JWT → `PUT /api/Productionworking/barcodes`). Shows the
  list, requires typing PULL, writes `scan_pull_result_<ts>.csv`. Verified with fake barcodes only.
- v1.5.0 (2026-10-08): **Submit Scan Pull** button → confirm dialog → `lib/tpm_api.dart` posts the
  list to staging TPM (same API-user JWT flow as `scan_pull.py`) → results screen (pulled/failed per
  barcode, failures first). Pulled barcodes leave the list; failed ones stay. Staging + WHISKERS
  credentials are hard-coded in `tpm_api.dart`. Added INTERNET permission to the main manifest
  (release builds had none). Verified on the server: 377127428126 pulled (isScanPull=true);
  377127428226/326/426 left for device testing.
- v1.6.0 (2026-10-08): RS36 diagnostics showed only the trigger key (`Key null char=null`), no data —
  ReaderConfig on the RS36 has no Intent option the user could find. Cause: our receiver listened for
  `...PASS_DATA`; CipherLab's real action is `com.cipherlab.barcodebaseapi.PASS_DATA_2_APP` (extra
  `Decoder_Data`), and the RS36 default output is the CipherLab input method. Fix: bundled CipherLab's
  `BarcodeAPI_V1_1_33.jar` (from npm `cordova-plugin-cipherlab-barcode-reader` 1.0.2, MIT) in
  `android/app/libs`; `MainActivity` sets keyboard emulation to None while the app is in the
  foreground and restores the previous value in onPause. Needs `<queries>` for
  `com.cipherlab.clbarcodeservice` and a ProGuard keep rule. Awaiting device test.
- v1.6.0 confirmed working on the RS36 by the user (2026-10-08).
- v1.7.0 (2026-10-08): **per-user Brijj sign-in** replaces the hard-coded API user. Login page →
  `POST company-api/api/Auth/SignIn {userName,password}` (no company code — it comes from the user)
  → JWT (1h) + refresh token (`/api/Auth/Refresh` returns a new accessToken only). Sign-in is refused
  unless `GET /api/Users/{id}/Permissions` includes TPMPortal **`Item:ScanPull`** (if that call
  fails, TPM's own 403 is the check). Session saved in app-private `session.json`; account button
  shows the user and signs out (`/api/Auth/SignOut`), clearing the scan list so the next user can't
  pull it under their name. TPM records the puller in ProductionHistory `lastUpdatedByUserName`
  (verified: 377127428226 pulled as automation99 → "Automation User"; the API user records blank).
  Still staging only. Test user: automation99 (password in `../APIExtract/FINDINGS.md`).
- v1.8.0 (2026-10-08): **Landi M20** — its scanner puts scans on the clipboard, which the app
  ignored. `MainActivity` now listens for clipboard changes while in the foreground; a single-token
  clip (no spaces, ≤64 chars) is taken as a scan and the clipboard is cleared. Other text is logged
  in diagnostics as ignored. Awaiting device test.
- v1.9.0 (2026-10-08): scan field hides the on-screen keyboard by default (`TextInputType.none`,
  still focused so keystroke scanners work); keyboard button in the field toggles it for typing.
  The Landi clipboard pop-up can't be suppressed by the app (it's Android's copy/paste notice) —
  the fix is switching the M20 scanner output off Clipboard (Keyboard/Broadcast).
- v1.9.1 (2026-10-08): user switched the M20 scanner off Clipboard (works); keyboard still showed
  on the M20 despite `TextInputType.none`. Added belt-and-braces hiding: `scan_pull/keyboard`
  MethodChannel → `InputMethodManager.hideSoftInputFromWindow`, called (with TextInput.hide) on
  focus, at startup and after each scan (0/150/400 ms), plus `stateAlwaysHidden`. Awaiting test.
- v1.9.1 keyboard fix confirmed on the M20 (2026-10-08).
- v1.10.0 (2026-10-08): **item details on scan.** Each scan looks the barcode up in TPM
  (`GET /api/ProductionHistory?barcode=&includeDeleted=true` — exact match, ~0.4 s; errors without
  includeDeleted) and shows dept › category · price, brand/size/quality, store/location, produced
  date, week-color avatar, and a status (✓ ready / ⛔ not found / already scan pulled / deleted /
  ↻ retry on lookup failure). Summary bar: N to pull · $total · flagged · checking. Submit skips
  flagged items (reported as "Skipped — …" on the results screen, left in the list); items still
  loading or with failed lookups are sent and TPM decides. Results show details and pulled value.
- v1.11.0 (2026-10-08): **week color names + offline.** Color chip per item: name from
  `GET /api/ProductionCycle?CompanyId=` (cycle id → displayName; items' own displayName is null)
  and week number from `/api/ProductionCycle/ByDate?CompanyId=&Date=`. Offline: network failures
  raise `OfflineException`; scans keep being added, lookups are queued ("waiting", cloud-off icon),
  last known details persist in `lookup_cache.json` (cleared on sign-out). Catch-up runs on
  connectivity change (`connectivity_plus`), every 30 s while anything is waiting, and on launch.
  Submit is disabled offline; an offline banner shows. Verified offline detection under
  `unshare -n`. Awaiting device test.
- v1.12.0 (2026-10-08): **destination picker — TPM Scan Pull or an IMS Scan Pull location.**
  Inventory API `inventory-api.stg.rcscbs.com` (same JWT). Scan Pull locations = locations whose
  profile has `isScanPull` — **only `GET /api/WarehouseLocationProfiles/{id}` reports it; the
  list/Lite responses say false for every profile.** Staging: Memphis / Scan Pull - Memphis (1610,
  wh 262, profile 457). Item in IMS: `GET /api/ProductSerials?CompanyId&WarehouseId&SearchTerm=<barcode>`
  (WarehouseId required; searched in every warehouse). Move = `POST /api/MovementOrders/Quick`
  mirroring IMS web Quick Relocation (`876.js` doQickRelocation): type 1 Relocate, relocationType 3
  Product, priority 3, status 2, movementOrderProcessType 2, per item {status 1, source/dest location,
  productId, quantity 1, serials:[{productSerialId}]}; response status 5 Completed / 3 Queued.
  Verified live with 377127428326 (Processing → Scan Pull - Memphis, cross-warehouse OK):
  MO-99-261008-0001 completed, completedBy = Automation User, TPM isScanPull=true. **IMS still lists
  the serial at the old Processing location too** (ghost record) — raise with dev. App flags "Not in
  IMS inventory" / "Already in <location>"; destination + location list cached in lookup_cache.json.
- 2026-10-08: user ruled out license-plate → Scan Pull (not a real workflow). Real flow is
  **Sales Floor → Scan Pull or Scrap**. Staging has no live Scrap location (Scrap Profile 291 says
  2 locations but none exist; old "Scrap" 857 is gone). Scrap Profile and Transfer Bin (Processing -
  Transfers, where produced items sit) both have Adjust Stock on and isScanPull off, so Adjust
  Stock alone can't identify Scrap destinations — waiting on the user for the rule.
- v1.13.0 (2026-10-08): user rules — **Scrap = Scan Pull** (no separate Scrap destination);
  **only Sales Floor → Scan Pull**, never the reverse; **IMS move is primary**, TPM Scan Pull only
  when the company has no Scan Pull location. Destination auto-resolves (on launch, reconnect and
  before submit; keeps the user's pick if it still exists; picker only when 2+ locations). Sales
  floor = "sales floor" in the location or profile name, same warehouse as the Scan Pull location
  (`ScanPullLocation.salesFloorIds`). Off-floor items flagged "Not on the <wh> sales floor (<loc>)".
  Lookup/skip rules moved to `lib/lookup.dart` (pure Dart, testable). Verified rules against
  staging: 3739654425 (Memphis Sales Floor) ready; Scrap-location item and 377127428426
  (Processing - Transfers) flagged. Needs Memphis Sales Floor test items for a device test.
- v1.13.1 (2026-10-08): first device pull to Scan Pull - Memphis (MO-99-261008-0002,
  377127433926, Sales Floor → Scan Pull, completedBy FirstWhiskers LastWhiskers, TPM pulled) showed
  "Scan Pull not submitted": IMS returns **201 Created** and `_send` only accepted 200. Now any 2xx
  is success; error text points to IMS movement orders in location mode.
- v1.14.0 (2026-10-08): **becoming an inventory app** (launcher label "Brijj Inventory"; package id
  unchanged). After sign-in a **HomePage** lists tasks: Scan Pull (live, badge = unsubmitted count),
  Transfers and Inventory Count (disabled "Coming soon" placeholders). Sign-out on Home clears the
  saved scan list + lookup cache. **Offline:** once offline, scans are only queued (no lookup
  attempts); a probe (`colorNames`) runs every 30 s and on connectivity regained; success resumes
  the catch-up and destination check. Launch checks connectivity first. Widget test:
  `test/home_page_test.dart`.
- v1.15.0 (2026-10-08): **Staging / Production toggle** on the sign-in page (staging goes down
  nightly). `BrijjEnv` in `tpm_api.dart`: staging = `*.stg.rcscbs.com`, production = `*.brijjworks.com`
  (company-api / productionsystem-api / inventory-api; prod hosts and endpoints probed — they answer
  400/401, not 404). The env is saved in the session (`session.json` `env`; older sessions = staging),
  so every call after sign-in goes to the server signed in to; switching = sign out and pick the other
  (sign-out already clears scans + lookup cache). Last pick remembered in `env.txt`. Production shows
  a red PRODUCTION corner ribbon on every screen and in the submit dialog title. Not yet tested with a
  real production login. Test: `test/env_switch_test.dart`. `scan_pull.py` is still staging only.
- v1.16.0 (2026-10-08): **self-update.** `lib/updater.dart` reads
  `https://apps.whiskeredwoodworker.com/brijj-inventory/version.json` on launch/resume (and when the
  Home account dialog opens), compares `build` with the app's versionCode, shows an "Update available"
  card on sign-in + Home → downloads `ScanPull-<ver>.apk` to cache/updates → Android installer (one
  tap; silent installs would need MDM). Native side: `scan_pull/update` channel in `MainActivity`,
  `REQUEST_INSTALL_PACKAGES`, FileProvider `${applicationId}.updates`. First time per device Android
  asks to allow "install unknown apps" for Brijj Inventory. Feed is served by the `apps-site` nginx
  container on HoloDev (`/Quarks/Data/DockerCompose/AppsSite`, port 8091, files in
  `/Quarks/Data/Dockers/AppsSite/`) — separate from static-pages so its personal pages stay private.
  Cloudflare DNS `apps` set up by the user; NPM proxy host 15 (apps → 192.168.1.215:8091, Let's
  Encrypt cert 11, forced SSL) created via the NPM API (login is in Homepage `services.yaml`).
  Verified publicly: version.json no-store, APK served with the right type and downloads intact.
  **Download page** at the site root (`/Quarks/Data/Dockers/AppsSite/index.html`): reads
  version.json, so its Download button always points at the newest APK — no edits per release;
  install steps + QR code of the page (qrcode-generator 1.4.4 from cdnjs); noindex. Updates only work while the signing key stays the
  same (currently the debug key in `tools/android-user/debug.keystore` — back it up).
- v1.17.0 (2026-10-08): **Brijj branding**, published as the first in-app update. Logos pulled from
  brijjworks.com (`wp-content/uploads/2025/05/favicon.png` = "b" mark 512px, `2026/06/brijj-logo.png`
  = "brijj" wordmark, `2025/05/brijjworks-logo.png`); brand colors blue `#0070B9`, green `#54BB70`.
  Adaptive launcher icon (white bg, mark 50% of the 108dp canvas, monochrome layer) + legacy mipmaps +
  pre-12 splash `drawable-nodpi/splash_logo.png`, generated with PIL. Theme primary = Brijj blue,
  secondary = green; sign-in page shows the wordmark + "Inventory" (no app bar); Home app bar shows
  the mark. Assets in `app/assets/`. Download page icon/accent updated too.
- v1.18.0 (2026-10-08): **Brijj look throughout**, matched to brijjworks.com's CSS: `lib/brand.dart`
  holds the palette (blue `#0070B9`, green `#54BB70`, ink `#111`, body text `#58564F`, sand background
  `#F3EEEC`, warm hairline `#E4DDD9`, tints; status success = dark green `#2E8B4E`, warning orange,
  danger red) and `brijjTheme()` (Fraunces 600 headings, Inter body — TTFs bundled in
  `assets/fonts`, OFL; white app bars with a hairline, 20px cards, pill buttons, 16px inputs, green
  Camera FAB). All hard-coded colors in `main.dart` now use brand constants — **use them for new
  screens instead of `Colors.*`**. Download page uses the same fonts/colors.
- v1.19.0 (2026-10-08): **user's profile picture** replaces the account icon (Home + Scan Pull app
  bars, larger in the account dialogs). Source found in the IMS portal's own code
  (inventory.brijjworks.com main.js): `GET company-api/api/Users/{id}/Lite` → `profileFileUrl`
  (portal maps it to `profileImgUrl`, placeholder when empty). `lib/user_photo.dart`: cached in
  app-private `user_photo.img`, refreshed on launch/sign-in, deleted on sign-out (a download
  finishing after sign-out is dropped); initials on Brijj blue when there's no picture or it can't
  be decoded. Endpoint confirmed on prod (401, not 404) but **not yet tested with a real user that
  has a picture** — staging was down; the URL's host/auth (public vs signed) is unknown.
- Open: smaller per-ABI APK once the terminal
  model is known.
- Builds go to `release/` **and** the self-update feed: after `flutter build apk --release` run
  `./publish.sh "notes for the update card"` (copies to both, writes version.json last, keeps 3 APKs).

## Layout

| Path | Contents |
|---|---|
| `release/ScanPull.apk` | Latest sideloadable build — copy the new APK here after every build |
| `app/` | Flutter project (`com.brijjworks.scan_pull`, Android only) |
| `app/lib/tpm_api.dart` | `BrijjEnv` (staging/production hosts), Brijj sign-in/refresh/sign-out, Scan Pull permission check, PUT barcodes |
| `app/lib/lookup.dart` | Per-barcode TPM/IMS state and the skip rules (sales floor only, already pulled…) |
| `app/lib/main.dart` | Whole app: `ScanStore` (list + file + CSV), `ScanListPage`, `CameraScanPage` |
| `app/lib/updater.dart` | Self-update: version.json check, APK download, installer hand-off, `UpdateCard` |
| `publish.sh` | Copy the release build to `release/` + the update feed and write `version.json` |
| `scan_pull.py` | CSV → TPM Scan Pull API (staging only): `python3 scan_pull.py scans.csv` — API user in `.env` (`BRIJJ_API_USER`/`BRIJJ_API_PASSWORD`, gitignored) |
| `documentation.md` | Design notes, build/install steps, open items |

## Build

Toolchain lives under `/Quarks/Data/DevOps/tools` (Flutter, Android SDK, JDK 17, caches) — the HoloDev
root disk is nearly full, so never let Gradle/pub/temp default to `/root` or `/tmp`.

```bash
source /Quarks/Data/DevOps/tools/flutter-env.sh
cd /Quarks/Data/DevOps/claude/BrijjPOS/ScanPull/app
flutter analyze
flutter build apk --release      # → build/app/outputs/flutter-apk/app-release.apk
```

Release builds are signed with the debug key (fine for sideloading a POC, not for Play Store).
The APK is ~66 MB because it bundles arm64, armv7 and x86_64; `--split-per-abi` gives smaller per-device APKs.

HoloDev's LXC has a hard 3 GB limit and the kernel OOM-kills Gradle above it. Gradle is capped in
`tools/gradle-home/gradle.properties` (1 GB heap, 512 MB metaspace, 1 worker, no daemon) — don't raise
it — and release lint is off in `app/android/app/build.gradle.kts` because it ran out of Metaspace.
The first build takes ~9 minutes (dependency downloads); later builds ~1 minute.
