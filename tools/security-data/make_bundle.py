#!/usr/bin/env python3
"""Assemble security-data.json from the bundled resource files (T-6.3).

Reads Packages/QRGuardKit/Sources/QRGuardCore/Resources/{brands,shorteners,suspicious_tlds,app_schemes,
payment_mobility,blocklist,bait_keywords}.json and writes one SecurityDataBundle document:

  { "schemaVersion": 1, "publishedAt": "<ISO 8601 UTC>", "sequence": N,
    "brands": [...], "shorteners": [...], "suspiciousTLDs": [...], "appSchemes": [...],
    "paymentMobility": [...], "blocklist": {...}, "baitKeywords": [...] }

The sequence is incremented from --previous (an earlier security-data.json) when given, otherwise from
--sequence, otherwise it starts at 1. The app rejects any bundle whose sequence is <= the one it already
applied, so always publish with a strictly increasing sequence.

Usage:
  make_bundle.py --out dist/security-data.json [--previous dist/security-data.json] [--sequence N]
                 [--only brands,blocklist] [--resources PATH]
Then sign:  sign.py sign --key <PRIVATE> --in dist/security-data.json
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RESOURCES = REPO_ROOT / "Packages/QRGuardKit/Sources/QRGuardCore/Resources"

# bundle key -> resource file name (without .json)
FIELDS = {
    "brands": "brands",
    "shorteners": "shorteners",
    "suspiciousTLDs": "suspicious_tlds",
    "appSchemes": "app_schemes",
    "paymentMobility": "payment_mobility",
    "blocklist": "blocklist",
    "baitKeywords": "bait_keywords",
}
SCHEMA_VERSION = 1


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True, help="output security-data.json path")
    parser.add_argument("--previous", type=Path, help="previously published security-data.json (sequence + 1)")
    parser.add_argument("--sequence", type=int, help="explicit sequence (overrides --previous)")
    parser.add_argument("--only", help="comma-separated subset of fields: " + ",".join(FIELDS))
    parser.add_argument("--resources", type=Path, default=DEFAULT_RESOURCES)
    parser.add_argument("--published-at", help="ISO 8601 timestamp (default: now, UTC)")
    args = parser.parse_args(argv)

    fields = list(FIELDS)
    if args.only:
        fields = [f.strip() for f in args.only.split(",") if f.strip()]
        unknown = [f for f in fields if f not in FIELDS]
        if unknown:
            parser.error(f"unknown field(s): {', '.join(unknown)}")

    if args.sequence is not None:
        sequence = args.sequence
    elif args.previous:
        prev = load_json(args.previous)
        sequence = int(prev.get("sequence", 0)) + 1
    else:
        sequence = 1
    if sequence < 1:
        parser.error("sequence must be >= 1")

    published = args.published_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    bundle = {"schemaVersion": SCHEMA_VERSION, "publishedAt": published, "sequence": sequence}
    stats = []
    for field in fields:
        path = args.resources / f"{FIELDS[field]}.json"
        if not path.exists():
            print(f"warning: {path} missing — field '{field}' omitted (app keeps bundled data)", file=sys.stderr)
            continue
        value = load_json(path)
        bundle[field] = value
        count = len(value) if isinstance(value, list) else sum(len(v) for v in value.values() if isinstance(v, list))
        stats.append((field, count))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    # Compact but stable formatting. The signature covers these exact bytes; do not reformat afterwards.
    text = json.dumps(bundle, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    args.out.write_bytes(text.encode("utf-8"))

    print(f"wrote {args.out}  sequence={sequence} publishedAt={published}")
    for field, count in stats:
        print(f"  {field:<16} {count:>6} entries")
    print("next: sign.py sign --key <PRIVATE_KEY> --in", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
