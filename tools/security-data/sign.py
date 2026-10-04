#!/usr/bin/env python3
"""Ed25519 keygen / sign / verify for QR Guard security-data (T-6.3).

Usage:
  sign.py keygen [--out-private PRIV.txt] [--out-public PUB.txt]
  sign.py sign   --key PRIV.txt --in security-data.json [--out security-data.json.sig]
  sign.py verify --pub PUB.txt  --in security-data.json [--sig security-data.json.sig]

Key files: raw 32-byte Ed25519 seed / public key, base64, one line. Lines starting with '#' are ignored.
The signature is a detached 64-byte Ed25519 signature over the EXACT bytes of the JSON file, base64 encoded,
which is what QRGuardCore.SecurityDataVerifier checks. Never re-serialize the JSON after signing.

Requires the 'cryptography' package. sign.swift in this folder is a dependency-free macOS equivalent.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import sys
from pathlib import Path

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "error: the 'cryptography' package is not installed.\n"
        "  Install it:   python3 -m pip install --user cryptography\n"
        "  Or use the dependency-free Swift tool on macOS:\n"
        "                swift tools/security-data/sign.swift <keygen|sign|verify> ...\n"
    )
    sys.exit(2)


def read_key_bytes(path: Path) -> bytes:
    body = "".join(
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.strip().startswith("#")
    )
    raw = base64.b64decode(body, validate=True)
    if len(raw) != 32:
        raise SystemExit(f"error: {path} is not a 32-byte raw Ed25519 key")
    return raw


def write_text(text: str, path: Path | None) -> None:
    if path is None:
        sys.stdout.write(text)
    else:
        path.write_text(text, encoding="utf-8")
        print(f"wrote {path}")


def cmd_keygen(args: argparse.Namespace) -> int:
    key = Ed25519PrivateKey.generate()
    priv = key.private_bytes(
        serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()
    )
    pub = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    write_text("# Ed25519 PRIVATE key (raw seed, base64). Keep secret.\n" + base64.b64encode(priv).decode() + "\n",
               args.out_private)
    write_text("# Ed25519 public key (raw 32 bytes, base64).\n" + base64.b64encode(pub).decode() + "\n",
               args.out_public)
    return 0


def cmd_sign(args: argparse.Namespace) -> int:
    key = Ed25519PrivateKey.from_private_bytes(read_key_bytes(args.key))
    data = args.input.read_bytes()
    signature = key.sign(data)
    out = args.out or Path(str(args.input) + ".sig")
    write_text(base64.b64encode(signature).decode() + "\n", out)
    print(f"sha256 {hashlib.sha256(data).hexdigest()}  ({len(data)} bytes)")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    pub = Ed25519PublicKey.from_public_bytes(read_key_bytes(args.pub))
    data = args.input.read_bytes()
    sig_path = args.sig or Path(str(args.input) + ".sig")
    signature = base64.b64decode(sig_path.read_text(encoding="utf-8").strip(), validate=True)
    try:
        pub.verify(signature, data)
    except InvalidSignature:
        print(f"error: signature INVALID for {args.input}", file=sys.stderr)
        return 1
    print(f"OK: signature valid for {args.input}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    k = sub.add_parser("keygen", help="generate a new Ed25519 keypair")
    k.add_argument("--out-private", type=Path)
    k.add_argument("--out-public", type=Path)
    k.set_defaults(func=cmd_keygen)

    s = sub.add_parser("sign", help="sign a JSON file (detached base64 signature)")
    s.add_argument("--key", type=Path, required=True)
    s.add_argument("--in", dest="input", type=Path, required=True)
    s.add_argument("--out", type=Path)
    s.set_defaults(func=cmd_sign)

    v = sub.add_parser("verify", help="verify a detached signature")
    v.add_argument("--pub", type=Path, required=True)
    v.add_argument("--in", dest="input", type=Path, required=True)
    v.add_argument("--sig", type=Path)
    v.set_defaults(func=cmd_verify)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
