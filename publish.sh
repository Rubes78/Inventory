#!/usr/bin/env bash
# Publishes the last release build: copies it to release/ and to the self-update feed
# (apps-site container, served at https://apps.whiskeredwoodworker.com/brijj-inventory/).
# Usage: ./publish.sh "What changed (shown on the update card)"
# Run after `flutter build apk --release`. Devices see the update on next launch/resume.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
apk="$here/app/build/app/outputs/flutter-apk/app-release.apk"
feed=/Quarks/Data/Dockers/AppsSite/brijj-inventory
notes="${1:-}"

line=$(grep -E '^version:' "$here/app/pubspec.yaml" | awk '{print $2}')
version="${line%%+*}"; build="${line##*+}"
[[ -f "$apk" ]] || { echo "No build at $apk" >&2; exit 1; }
[[ "$apk" -nt "$here/app/pubspec.yaml" ]] || { echo "Build is older than pubspec.yaml — rebuild first" >&2; exit 1; }

cp "$apk" "$here/release/ScanPull.apk"
mkdir -p "$feed"
name="ScanPull-$version.apk"
cp "$apk" "$feed/$name"
size=$(stat -c %s "$feed/$name")
# Write version.json last (atomically), so devices never see it before the APK exists.
python3 - "$feed/version.json" "$version" "$build" "$name" "$size" "$notes" <<'PY'
import json, os, sys
from datetime import date
path, version, build, apk, size, notes = sys.argv[1:]
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump({'version': version, 'build': int(build), 'apk': apk, 'size': int(size), 'notes': notes,
               'published': date.today().isoformat()}, f, indent=2)
os.replace(tmp, path)
PY
# Keep the last 3 APKs on the server.
ls -1t "$feed"/ScanPull-*.apk | tail -n +4 | xargs -r rm --
echo "Published v$version ($build): release/ScanPull.apk and $feed/$name"
cat "$feed/version.json"
