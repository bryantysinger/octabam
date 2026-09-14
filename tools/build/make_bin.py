#!/usr/bin/env python3
"""Wrap a patched ELEK container into an ELUP `.bin` for the CF-card OS UPGRADE
path (manual 8.5.2: the `.bin` in the root of the card, PROJECT -> OS
UPGRADE). `tools/build/bin_decode.py` decodes the official file and validates
its checksum; this is the forward direction. The payload is

    [4-byte BE length][ELEK container]

    word[0]        magic 0x454C5550 "ELUP"
    word[1]        feedback seed
    word[2..n-2]   obfuscated payload
    word[n-1]      obfuscated additive checksum of the plain payload

The cipher is XOR-with-feedback; the per-word variant is chosen by bit
0x800000 of the previous cipher word. rot16 and bswap are involutions:

    encode:  x = k ^ mixer ^ p ;  c = rot16(x) ^ XOR_A   (variant 0)
                                  c = bswap(x) ^ XOR_B   (variant 1)

Usage:
    EFT_EMIT_CONTAINER=elek.bin elektron-firmware-tool -i stock.syx -c 3 mainos.bin \
        -V OCTABAM001 -o out.syx
    python3 tools/build/make_bin.py elek.bin -o OCTATRACK_OCTABAM001.bin

(`make image` runs both steps with the BUILD number stamped in.)
"""
import argparse, struct, sys
from pathlib import Path

MAGIC = 0x454C5550
XOR_A, XOR_B = 0x9E3B16A2, 0x764E28CA
C3, C7 = 0x360FA955, 0xEF4A9AB6
M = 0xFFFFFFFF
DEFAULT_SEED = 0x2F1349D2      # the seed the official 1.40C image uses


def rot16(v):
    return ((v << 16) | (v >> 16)) & M


def bswap(v):
    return (((v & 0xFF) << 24) | ((v & 0xFF00) << 8) |
            ((v & 0xFF0000) >> 8) | (v >> 24)) & M


def encode_word(k, p):
    """Cipher word for plain p, given k = previous cipher word (seed for the first)."""
    x = (k ^ (C3 if (k & 0x800000) == 0 else C7) ^ p) & M
    return (rot16(x) ^ XOR_A) & M if (k & 0x800000) == 0 else (bswap(x) ^ XOR_B) & M


def decode_word(k, c):
    if (k & 0x800000) == 0:
        return (k ^ C3 ^ rot16(c ^ XOR_A)) & M
    return (k ^ C7 ^ bswap(c ^ XOR_B)) & M


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("container", help="ELEK container (EFT_EMIT_CONTAINER output)")
    ap.add_argument("-o", "--out", required=True, help="output .bin")
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=DEFAULT_SEED)
    args = ap.parse_args()

    elek = Path(args.container).read_bytes()
    if elek[:4] != b"ELEK":
        sys.exit(f"{args.container} does not start with 'ELEK': {elek[:8]!r}")

    payload = struct.pack(">I", len(elek)) + elek
    pad = (-len(payload)) % 4
    if pad:
        payload += b"\x00" * pad
    words = list(struct.unpack(f">{len(payload)//4}I", payload))
    print(f"container : {len(elek):,} bytes  ({elek[:18].decode('ascii', 'replace')})")
    print(f"payload   : {len(payload):,} bytes"
          + (f"  (+{pad} pad bytes to a word boundary)" if pad else ""))

    k, acc, cipher = args.seed, 0, []
    for p in words:
        c = encode_word(k, p)
        cipher.append(c)
        acc = (acc + p) & M
        k = c
    cipher.append(encode_word(k, acc))       # checksum, enciphered like a payload word

    out = struct.pack(">II", MAGIC, args.seed) + struct.pack(f">{len(cipher)}I", *cipher)
    Path(args.out).write_bytes(out)

    # round-trip with the decoder's own logic before claiming success
    k, acc2, plain = args.seed, 0, []
    for c in cipher[:-1]:
        p = decode_word(k, c)
        plain.append(p)
        acc2 = (acc2 + p) & M
        k = c
    ok_payload = struct.pack(f">{len(plain)}I", *plain) == payload
    ok_cksum = decode_word(k, cipher[-1]) == acc2 == acc
    print(f"checksum  : 0x{acc:08x}")
    print(f"round-trip: payload {'ok' if ok_payload else 'MISMATCH'}, "
          f"checksum {'ok' if ok_cksum else 'MISMATCH'}")
    if not (ok_payload and ok_cksum):
        sys.exit("refusing to ship a file that does not decode back to its input")
    print(f"\nwrote {args.out} ({len(out):,} bytes)")
    print("Copy it to the ROOT of the CF card, then PROJECT -> OS UPGRADE -> [YES].")


if __name__ == "__main__":
    main()
