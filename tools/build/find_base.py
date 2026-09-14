#!/usr/bin/env python3
"""Find a raw firmware's load base by pointer->string correlation.

If the image loads at base B, a string at file offset F lives at virtual
address B+F, and absolute 32-bit pointers in the code that reference it hold
B+F. The B that maximises the number of pointers landing exactly on a
string's first byte is the load base.

Usage: python3 find_base.py <raw.bin> [--top-byte 0x40] [--min-str 5]
"""
import argparse
import struct
from collections import Counter
from pathlib import Path


def find_strings(data, min_len):
    """Devuelve set de offsets de inicio de runs ASCII imprimibles terminados en NUL."""
    starts = {}
    i, n = 0, len(data)
    while i < n:
        b = data[i]
        if 0x20 <= b < 0x7f:
            j = i
            while j < n and 0x20 <= data[j] < 0x7f:
                j += 1
            if j - i >= min_len:
                starts[i] = data[i:j].decode("ascii", "replace")
            i = j
        else:
            i += 1
    return starts


def words_be(data, top_byte):
    """Genera (pos, valor) de words de 32 bits big-endian en offsets pares cuyo byte
    alto == top_byte (region candidata de punteros)."""
    for pos in range(0, len(data) - 3, 2):
        if data[pos] == top_byte:
            yield pos, struct.unpack_from(">I", data, pos)[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--top-byte", default="0x40")
    ap.add_argument("--min-str", type=int, default=5)
    ap.add_argument("--csv", help="volcar mapa completo ptr->string a este CSV")
    args = ap.parse_args()
    top = int(args.top_byte, 0)

    data = Path(args.file).read_bytes()
    strings = find_strings(data, args.min_str)
    str_offsets = set(strings)
    print(f"[find_base] {args.file}: {len(data)} bytes, {len(strings)} strings (>= {args.min_str} chars)")
    print(f"[find_base] scanning pointers with top byte {hex(top)} ...")

    # vote: for each pointer P in the region, the implied base is P - F when it points at a string
    # Como F < tamano de imagen, para cada P probamos B = P - F solo si (P - B) es un
    # offset de string valido. Equivalente: para cada string F, ¿existe P == B + F?
    # count votes for each candidate base B = P - F, F bounded to the image
    votes = Counter()
    ptrs = list(words_be(data, top))
    n = len(data)
    for _, P in ptrs:
        # a candidate base must keep every offset inside [0, n)
        # Solo consideramos que P apunta a ALGUN string: B = P - F, F en str_offsets
        # try the implied "round" base; iterate strings only if the pointer
        # count is manageable
        pass

    # for a set of candidate bases (a coarse sweep + the 0x40000000
    # hypothesis), count the pointers that land on a string start
    candidates = sorted({top << 24} | {(top << 24) + off for off in (0, 0x1000, 0x2000)})
    # a fine sweep around top<<24, in case of a header/load offset
    base_lo = top << 24
    for delta in range(0, 0x20001, 4):
        candidates.append(base_lo + delta)
    candidates = sorted(set(candidates))

    ptr_vals = [P for _, P in ptrs]
    ptr_set = set(ptr_vals)
    best = []
    for B in candidates:
        # how many strings F have an exact pointer B+F present
        hits = sum(1 for F in str_offsets if (B + F) in ptr_set)
        if hits:
            best.append((hits, B))
    best.sort(reverse=True)

    print("\n[find_base] top bases by strings referenced by an exact pointer:")
    for hits, B in best[:8]:
        print(f"   base 0x{B:08x}  ->  {hits} strings with a direct pointer")

    if not best:
        print("   (sin coincidencias; prueba otro --top-byte o revisa endianness)")
        return

    B = best[0][1]
    print(f"\n[find_base] BASE ELEGIDA: 0x{B:08x}")

    matches = [(pos, P, P - B) for pos, P in ptrs if (P - B) in strings]
    print(f"[find_base] {len(matches)} pointers resolve to a string start. Examples:")
    for pos, P, F in matches[:12]:
        s = strings[F][:48].replace("\n", " ")
        print(f"   @0x{pos:06x}: ptr 0x{P:08x} -> file+0x{F:06x} '{s}'")

    if args.csv:
        with open(args.csv, "w") as fh:
            fh.write("ptr_site_vaddr,ptr_value,string_vaddr,file_offset,string\n")
            for pos, P, F in matches:
                s = strings[F].replace('"', '""')
                fh.write(f'0x{B+pos:08x},0x{P:08x},0x{B+F:08x},0x{F:06x},"{s}"\n')
        print(f"[find_base] mapa completo -> {args.csv} ({len(matches)} filas)")


if __name__ == "__main__":
    main()
