#!/usr/bin/env bash
# Disassembly helper for the decompressed MAIN OS (ColdFire, m68k big-endian).
#
# This is the ColdFire side -- the OS itself. The audio effects run on the
# DSP56300 and are a different toolchain entirely: see tools/build/dsp_disasm_all.py
# and docs/firmware/DSP.md.
#
# r2's m68k backend cannot decode this CPU's ColdFire V4e extensions: every
# `macl`/`msacl`/`movclrl`, `mvz` and `mvs` comes back `invalid`, and since r2
# then treats the opcode as 2 bytes, each extension word is decoded as a
# separate plausible instruction and the stream desynchronises (6,757
# undecodable instructions below 0x40098000, 4,543 of them longer than two
# bytes). Use the `emac` subcommand (objdump -m m68k:cfv4e) whenever the
# answer matters.
#
# Usage:
#   scripts/disasm.sh                 open r2 interactively on the raw image
#   scripts/disasm.sh strings         dump every string with its offset
#   scripts/disasm.sh pd 0x1000       run an r2 expression and exit
#   scripts/disasm.sh emac 0x40003664 [n]   objdump -m m68k:cfv4e, correct
set -euo pipefail
cd "$(dirname "$0")/.."

RAW="${RAW:-out/raw/section_3_MAIN_OS.bin}"
[ -f "$RAW" ] || { echo "$RAW not found — run scripts/analyze.sh first." >&2; exit 1; }

# m68k big-endian covers most of the ColdFire ISA -- but NOT the EMAC; see the
# warning above, and use the `emac` subcommand for those regions.
# Load base determined empirically (tools/build/find_base.py): 0x40000400
# (image in SDRAM at 0x40000000 + 0x400 of header/vectors). Data/BSS ~0x400bxxxx.
BASE="${BASE:-0x40000400}"
# -m maps the raw at the base (-B does not remap raw files in r2).
R2FLAGS=(-a m68k -b 32 -e cfg.bigendian=true -m "$BASE")

case "${1:-}" in
  emac)
    # EMAC-correct disassembly of one span. objdump, not r2 -- see the warning
    # at the top of this file. Needs m68k-elf-objdump (scripts/setup.sh).
    ADDR="${2:?usage: scripts/disasm.sh emac <addr> [bytes]}"
    N="${3:-128}"
    command -v m68k-elf-objdump >/dev/null || {
      echo "m68k-elf-objdump not found -- it is what decodes EMAC correctly." >&2
      exit 1; }
    OFF=$(( ADDR - BASE ))
    [ "$OFF" -ge 0 ] || { echo "address is below the load base $BASE" >&2; exit 1; }
    TMP=$(mktemp)
    dd if="$RAW" of="$TMP" bs=1 skip="$OFF" count="$N" 2>/dev/null
    m68k-elf-objdump -D -b binary -m m68k:cfv4e --adjust-vma="$ADDR" "$TMP" \
      | tail -n +7
    rm -f "$TMP"
    ;;
  strings)
    r2 -q "${R2FLAGS[@]}" -c 'e bin.str.raw=true; izz~...' "$RAW" 2>/dev/null || \
      strings -t x -n 6 "$RAW"
    ;;
  "")
    echo "Opening r2 (m68k BE). Useful commands:"
    echo "  aaa            analyse    |  pd 40      disassemble   |  izz  strings"
    echo "  afl            functions  |  s <addr>   seek          |  V    visual mode"
    exec r2 "${R2FLAGS[@]}" "$RAW"
    ;;
  *)
    r2 -q "${R2FLAGS[@]}" -c "$*" "$RAW"
    ;;
esac
