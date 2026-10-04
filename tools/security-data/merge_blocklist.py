#!/usr/bin/env python3
"""Merge an external phishing-URL export into a blocklist.json-shaped file (T-6.4).

This script does NOT download anything. Export the dataset yourself (e.g. the KISA phishing-site URL dataset
from 공공데이터포털) after confirming its format and license terms, then run:

  merge_blocklist.py --input export.csv --column url --out blocklist.merged.json \
      --base Packages/QRGuardKit/Sources/QRGuardCore/Resources/blocklist.json \
      --source "KISA 피싱사이트 URL (data.go.kr), 2026-10" [--mode host|domain|prefix] [--dry-run]

Input: CSV (header row required) or JSON (array of objects, or array of strings). --column selects the
field holding the URL / host / domain. --mode decides where entries go:
  host    (default) → "hosts":      exact host names (scheme/path/port/userinfo stripped, lowercased)
  domain            → "domains":    registrable-domain style entries (matches the domain and all subdomains)
  prefix            → "urlPrefixes": full URL prefixes (scheme + host + path, lowercased, query/fragment dropped)

Normalization: trim, lowercase, strip scheme/userinfo/port/trailing dots, IDN → punycode, de-duplicate,
drop empty/invalid values. Reserved or local names (localhost, *.local, *.test, *.example, *.invalid,
example.com/net/org, private IPs) are skipped with a warning because they would only ever match test traffic.

Output keeps the Blocklist shape used by QRGuardCore: {domains, hosts, urlPrefixes, source, updatedAt}.
"""
from __future__ import annotations

import argparse
import csv
import ipaddress
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

RESERVED_SUFFIXES = (".test", ".example", ".invalid", ".localhost", ".local", ".internal", ".home.arpa", ".lan")
RESERVED_HOSTS = {"localhost", "example.com", "example.net", "example.org", "example.test"}
HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")


def is_reserved(host: str) -> bool:
    if host in RESERVED_HOSTS or host.endswith(RESERVED_SUFFIXES):
        return True
    for h in RESERVED_HOSTS:
        if host.endswith("." + h):
            return True
    try:
        ip = ipaddress.ip_address(host.strip("[]"))
        return ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast
    except ValueError:
        return False


def split_url(raw: str) -> tuple[str, str, str] | None:
    """Return (scheme, host, path) or None if unusable."""
    text = raw.strip()
    if not text:
        return None
    if "://" not in text:
        text = "http://" + text
    parts = urlsplit(text)
    host = (parts.hostname or "").strip().rstrip(".").lower()
    if not host:
        return None
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        return None
    is_ip = False
    try:
        ipaddress.ip_address(host)
        is_ip = True
    except ValueError:
        pass
    if not is_ip and not HOST_RE.match(host):
        return None
    scheme = (parts.scheme or "http").lower()
    if scheme not in ("http", "https"):
        return None
    return scheme, host, parts.path or "/"


def read_rows(path: Path, column: str) -> list[str]:
    if path.suffix.lower() == ".json":
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            # allow {"data": [...]} / {"items": [...]} style exports
            for key in ("data", "items", "records", "rows"):
                if isinstance(data.get(key), list):
                    data = data[key]
                    break
        if not isinstance(data, list):
            raise SystemExit("error: JSON input must be an array (or an object with a data/items/records/rows array)")
        values = []
        for row in data:
            if isinstance(row, str):
                values.append(row)
            elif isinstance(row, dict) and column in row and row[column] is not None:
                values.append(str(row[column]))
        return values
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None or column not in reader.fieldnames:
            raise SystemExit(f"error: column '{column}' not found; available: {reader.fieldnames}")
        return [row[column] for row in reader if row.get(column)]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, required=True, help="CSV or JSON export")
    parser.add_argument("--column", default="url", help="field holding url/host/domain (default: url)")
    parser.add_argument("--mode", choices=("host", "domain", "prefix"), default="host")
    parser.add_argument("--base", type=Path, help="existing blocklist.json to merge into")
    parser.add_argument("--out", type=Path, help="output path (default: stdout)")
    parser.add_argument("--source", required=True, help="provenance text recorded in 'source'")
    parser.add_argument("--updated-at", help="date recorded in 'updatedAt' (default: today, UTC)")
    parser.add_argument("--dry-run", action="store_true", help="print stats only, write nothing")
    args = parser.parse_args(argv)

    base = {"domains": [], "hosts": [], "urlPrefixes": []}
    if args.base:
        loaded = json.loads(args.base.read_text(encoding="utf-8"))
        for key in base:
            base[key] = list(loaded.get(key, []))
    before = {k: len(v) for k, v in base.items()}

    rows = read_rows(args.input, args.column)
    seen: set[str] = set()
    added: list[str] = []
    skipped_invalid = skipped_reserved = skipped_dupe = 0
    target_key = {"host": "hosts", "domain": "domains", "prefix": "urlPrefixes"}[args.mode]
    existing = set(x.lower() for x in base[target_key])

    for raw in rows:
        parsed = split_url(raw)
        if parsed is None:
            skipped_invalid += 1
            continue
        scheme, host, path = parsed
        if is_reserved(host):
            skipped_reserved += 1
            print(f"warning: skipping reserved/local entry: {raw.strip()}", file=sys.stderr)
            continue
        if args.mode == "prefix":
            entry = f"{scheme}://{host}{path}".lower()
        else:
            entry = host
        if entry in seen or entry in existing:
            skipped_dupe += 1
            continue
        seen.add(entry)
        added.append(entry)

    base[target_key].extend(sorted(added))
    result = {
        "domains": base["domains"],
        "hosts": base["hosts"],
        "urlPrefixes": base["urlPrefixes"],
        "source": args.source,
        "updatedAt": args.updated_at or datetime.now(timezone.utc).date().isoformat(),
    }

    print(f"input rows      : {len(rows)}")
    print(f"added ({target_key}): {len(added)}")
    print(f"skipped invalid : {skipped_invalid}")
    print(f"skipped reserved: {skipped_reserved}")
    print(f"skipped dupes   : {skipped_dupe}")
    for key in ("domains", "hosts", "urlPrefixes"):
        print(f"{key:<16}: {before[key]} -> {len(result[key])}")

    if args.dry_run:
        return 0
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
        print(f"wrote {args.out}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
