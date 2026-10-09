"""Send a Scan Pull app CSV straight into TPM Scan Pull — STAGING ONLY.

Signs in as the Whiskers API user (company-api SignIn -> 1h JWT), then
PUTs the barcodes to /api/Productionworking/barcodes on the staging TPM API.
Scan Pull removes items from TPM *and* POS and cannot be undone, so the list
is shown and must be confirmed before anything is sent.

    python3 scan_pull.py scans.csv [more.csv ...]
    python3 scan_pull.py --barcode 1000123 --barcode 1000124

Credentials come from BRIJJ_API_USER / BRIJJ_API_PASSWORD, or a gitignored
.env next to this script (KEY=value lines).

CSV format is the app's export: one barcode per line, no header.
A result log (barcode, result, message) is written next to the first input.
"""
import argparse
import csv
import os
import sys
from datetime import datetime
from pathlib import Path

import requests

# Staging only — never point this at brijjworks.com (production).
COMPANY_API = "https://company-api.stg.rcscbs.com"
TPM_API = "https://productionsystem-api.stg.rcscbs.com"

def _load_env():
    env = Path(__file__).with_name(".env")
    if env.exists():
        for line in env.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and not line.lstrip().startswith("#"):
                os.environ.setdefault(key.strip(), value.strip())


_load_env()
API_USERNAME = os.environ.get("BRIJJ_API_USER", "")
API_PASSWORD = os.environ.get("BRIJJ_API_PASSWORD", "")
COMPANY_CODE = "WHISKERS"

BATCH_SIZE = 100


def read_barcodes(paths, extra):
    seen, barcodes = set(), []
    for p in paths:
        with open(p, newline="", encoding="utf-8-sig") as f:
            for row in csv.reader(f):
                if row:
                    extra.append(row[0])
    for b in extra:
        b = b.strip()
        if b and b not in seen:
            seen.add(b)
            barcodes.append(b)
    return barcodes


def sign_in():
    if not API_USERNAME or not API_PASSWORD:
        sys.exit("Set BRIJJ_API_USER and BRIJJ_API_PASSWORD (environment or .env).")
    r = requests.post(f"{COMPANY_API}/api/Auth/SignIn", timeout=20, json={
        "username": API_USERNAME, "password": API_PASSWORD, "companyId": COMPANY_CODE})
    r.raise_for_status()
    data = r.json()
    if not data.get("isAuthenticated"):
        sys.exit(f"Sign-in failed: {data}")
    return data["accessToken"], data["company"]["name"]


def pull(token, barcodes):
    r = requests.put(f"{TPM_API}/api/Productionworking/barcodes", json=barcodes, timeout=60,
                     headers={"Authorization": f"Bearer {token}"})
    if r.status_code != 200:
        sys.exit(f"Scan pull failed: HTTP {r.status_code} {r.text[:500]}")
    return {f["serialNumber"]: f["message"] for f in r.json().get("failedToDeleteSerials", [])}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="*", help="Scan Pull app CSV export(s)")
    ap.add_argument("--barcode", action="append", default=[], help="add a barcode (repeatable)")
    ap.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    args = ap.parse_args()

    barcodes = read_barcodes(args.csv, list(args.barcode))
    if not barcodes:
        sys.exit("No barcodes given.")

    token, company = sign_in()
    print(f"STAGING  {TPM_API}\nCompany: {company} ({COMPANY_CODE})\n")
    for b in barcodes:
        print(f"  {b}")
    print(f"\n{len(barcodes)} barcode(s) will be removed from TPM and POS. This cannot be undone.")
    if not args.yes and input(f"Type PULL to continue: ").strip() != "PULL":
        sys.exit("Cancelled — nothing sent.")

    failed = {}
    for i in range(0, len(barcodes), BATCH_SIZE):
        failed.update(pull(token, barcodes[i:i + BATCH_SIZE]))

    log_dir = Path(args.csv[0]).resolve().parent if args.csv else Path.cwd()
    log = log_dir / f"scan_pull_result_{datetime.now():%Y%m%d_%H%M%S}.csv"
    with open(log, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["barcode", "result", "message"])
        for b in barcodes:
            w.writerow([b, "FAILED" if b in failed else "PULLED", failed.get(b, "")])

    print(f"\nPulled: {len(barcodes) - len(failed)}   Failed: {len(failed)}")
    for b, msg in failed.items():
        print(f"  FAILED {b}: {msg}")
    print(f"Log: {log}")


if __name__ == "__main__":
    main()
