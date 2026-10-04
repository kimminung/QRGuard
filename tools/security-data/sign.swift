#!/usr/bin/env swift
// sign.swift — Ed25519 keygen / sign / verify for QR Guard security-data (macOS, CryptoKit, no dependencies).
//
// Usage:
//   swift tools/security-data/sign.swift keygen [--out-private PRIV.txt] [--out-public PUB.txt]
//   swift tools/security-data/sign.swift sign   --key PRIV.txt --in security-data.json [--out security-data.json.sig]
//   swift tools/security-data/sign.swift verify --pub PUB.txt  --in security-data.json [--sig security-data.json.sig]
//
// Key files: raw 32-byte Ed25519 seed / public key, base64, one line. Lines starting with '#' are ignored.
// The signature is a detached 64-byte Ed25519 signature over the EXACT bytes of the JSON file, base64 encoded.
// sign.py produces byte-identical output; use whichever toolchain you have.
//
// If the compiler cannot find CryptoKit when run from a sandbox, pass a writable module cache:
//   swiftc -module-cache-path /tmp/mc -o /tmp/sign tools/security-data/sign.swift && /tmp/sign ...

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func readKeyText(_ path: String) -> Data {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    let body = text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .joined()
    guard let raw = Data(base64Encoded: body), raw.count == 32 else { fail("\(path) is not a base64 32-byte key") }
    return raw
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func write(_ text: String, to path: String?) {
    if let path {
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch { fail("cannot write \(path): \(error)") }
        print("wrote \(path)")
    } else {
        print(text)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: sign.swift keygen|sign|verify ... (see header comment)")
}

switch command {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    let priv = key.rawRepresentation.base64EncodedString()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    write("# Ed25519 PRIVATE key (raw seed, base64). Keep secret.\n" + priv + "\n", to: option("--out-private", in: args))
    write("# Ed25519 public key (raw 32 bytes, base64).\n" + pub + "\n", to: option("--out-public", in: args))

case "sign":
    guard let keyPath = option("--key", in: args), let inPath = option("--in", in: args) else { fail("sign requires --key and --in") }
    let key: Curve25519.Signing.PrivateKey
    do { key = try Curve25519.Signing.PrivateKey(rawRepresentation: readKeyText(keyPath)) } catch { fail("bad private key: \(error)") }
    guard let data = FileManager.default.contents(atPath: inPath) else { fail("cannot read \(inPath)") }
    let signature: Data
    do { signature = try key.signature(for: data) } catch { fail("signing failed: \(error)") }
    let outPath = option("--out", in: args) ?? (inPath + ".sig")
    write(signature.base64EncodedString() + "\n", to: outPath)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    print("sha256 \(digest)  (\(data.count) bytes)")

case "verify":
    guard let pubPath = option("--pub", in: args), let inPath = option("--in", in: args) else { fail("verify requires --pub and --in") }
    let pub: Curve25519.Signing.PublicKey
    do { pub = try Curve25519.Signing.PublicKey(rawRepresentation: readKeyText(pubPath)) } catch { fail("bad public key: \(error)") }
    guard let data = FileManager.default.contents(atPath: inPath) else { fail("cannot read \(inPath)") }
    let sigPath = option("--sig", in: args) ?? (inPath + ".sig")
    guard let sigText = try? String(contentsOfFile: sigPath, encoding: .utf8),
          let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("cannot read base64 signature at \(sigPath)")
    }
    if pub.isValidSignature(signature, for: data) {
        print("OK: signature valid for \(inPath)")
    } else {
        fail("signature INVALID for \(inPath)")
    }

default:
    fail("unknown command \(command). Use keygen | sign | verify")
}
