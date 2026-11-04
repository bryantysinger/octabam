#!/usr/bin/env python3
"""OBP1: the patch the web builder applies to the user's own stock MAIN OS.

A patch turns `out/raw/section_3_MAIN_OS.bin` (stock 1.40C, section 3 of the
container) into a remix's `out/mainos_bus.bin`. It holds octabam's bytes and
instructions to copy stock bytes from the user's own file; it holds no stock
byte as a literal run of MIN_STOCK bytes or more (`make()` refuses).

    header   "OBP1"
             sha256 of the stock input        (32)
             sha256 of the output             (32)
             u32le output length
    ops      varint-tagged stream, then the whole patch is deflated (zlib)
               tag = (n << 1) | kind
               kind 0, COPY: n bytes from stock at varint(offset)
               kind 1, LIT:  n bytes follow

`apply()` is mirrored by web/obpatch.js; `selftest()` pins the two together.
"""
import hashlib
import struct
import sys
import zlib

MAGIC = b"OBP1"
MIN_STOCK = 16      # a literal run may not contain a stock sequence this long
MIN_COPY = 6        # an equal run shorter than this is cheaper as literal bytes


def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _read_varint(buf, i):
    n = shift = 0
    while True:
        b = buf[i]
        i += 1
        n |= (b & 0x7F) << shift
        if not b & 0x80:
            return n, i
        shift += 7


def _trivial(g):
    """A sequence of at most two distinct byte values (zero fill, 0xff fill):
    present in any image, carries nothing of the stock OS."""
    return len(set(g)) <= 2


def _index(stock):
    idx = {}
    for i in range(len(stock) - MIN_STOCK + 1):
        g = stock[i:i + MIN_STOCK]
        if g not in idx and not _trivial(g):
            idx[g] = i
    return idx


def ops_for(stock, image, idx):
    """Greedy: extend the same-offset equal run, else a stock match found
    through the 16-byte index, else a literal byte."""
    ops = []                    # ("c", off, n) | ("l", bytes)
    lit = bytearray()
    n_img, n_st = len(image), len(stock)
    i = 0

    def flush():
        if lit:
            ops.append(("l", bytes(lit)))
            lit.clear()

    while i < n_img:
        if i < n_st and image[i] == stock[i]:
            j = i
            while j < n_img and j < n_st and image[j] == stock[j]:
                j += 1
            if j - i >= MIN_COPY:
                flush()
                ops.append(("c", i, j - i))
                i = j
                continue
        g = image[i:i + MIN_STOCK]
        if len(g) == MIN_STOCK and g in idx:
            off = idx[g]
            j = i + MIN_STOCK
            k = off + MIN_STOCK
            while j < n_img and k < n_st and image[j] == stock[k]:
                j += 1
                k += 1
            flush()
            ops.append(("c", off, j - i))
            i = j
            continue
        lit.append(image[i])
        i += 1
    flush()
    return ops


def make(stock, image):
    idx = _index(stock)
    ops = ops_for(stock, image, idx)
    body = bytearray()
    for op in ops:
        if op[0] == "c":
            body += _varint(op[2] << 1) + _varint(op[1])
        else:
            body += _varint(len(op[1]) << 1 | 1) + op[1]
    head = (MAGIC + hashlib.sha256(stock).digest() + hashlib.sha256(image).digest()
            + struct.pack("<I", len(image)))
    patch = zlib.compress(head + bytes(body), 9)
    # The refusal below reads the patch back, not the ops that made it.
    leaks = leaked(stock, patch, idx)
    if leaks:
        raise SystemExit(f"obpatch: {len(leaks)} literal run(s) carry a stock "
                         f"sequence of {MIN_STOCK}+ bytes, first at output offset "
                         f"0x{leaks[0]:x}")
    if apply(stock, patch) != image:
        raise SystemExit("obpatch: apply(stock, make(stock, image)) != image")
    return patch


def _walk(patch):
    raw = zlib.decompress(patch)
    if raw[:4] != MAGIC:
        raise ValueError("not an OBP1 patch")
    head = raw[4:72]
    stock_sha, out_sha = head[:32], head[32:64]
    (n_out,) = struct.unpack("<I", head[64:68])
    i = 72
    return raw, i, stock_sha, out_sha, n_out


def header(patch):
    """(stock sha256, output sha256, output length) without the stock input."""
    _, _, stock_sha, out_sha, n_out = _walk(patch)
    return stock_sha.hex(), out_sha.hex(), n_out


def apply(stock, patch):
    raw, i, stock_sha, out_sha, n_out = _walk(patch)
    if hashlib.sha256(stock).digest() != stock_sha:
        raise ValueError("this is not the stock MAIN OS the patch was made against")
    out = bytearray()
    while i < len(raw):
        tag, i = _read_varint(raw, i)
        n, kind = tag >> 1, tag & 1
        if kind == 0:
            off, i = _read_varint(raw, i)
            out += stock[off:off + n]
        else:
            out += raw[i:i + n]
            i += n
    if len(out) != n_out or hashlib.sha256(out).digest() != out_sha:
        raise ValueError("patched output does not match the recorded hash")
    return bytes(out)


def leaked(stock, patch, idx=None):
    """Output offsets of literal runs containing a non-trivial stock sequence."""
    idx = idx if idx is not None else _index(stock)
    raw, i, _, _, _ = _walk(patch)
    pos, bad = 0, []
    while i < len(raw):
        tag, i = _read_varint(raw, i)
        n, kind = tag >> 1, tag & 1
        if kind == 0:
            _, i = _read_varint(raw, i)
        else:
            lit = raw[i:i + n]
            for k in range(len(lit) - MIN_STOCK + 1):
                if lit[k:k + MIN_STOCK] in idx:
                    bad.append(pos + k)
                    break
            i += n
        pos += n
    return bad


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: obpatch.py STOCK_SECTION3.bin IMAGE.bin OUT.obp")
    stock = open(sys.argv[1], "rb").read()
    image = open(sys.argv[2], "rb").read()
    patch = make(stock, image)
    open(sys.argv[3], "wb").write(patch)
    print(f"{sys.argv[3]}: {len(patch)} bytes for a {len(image)}-byte image")


if __name__ == "__main__":
    main()
