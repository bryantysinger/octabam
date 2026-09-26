#!/usr/bin/env python3
"""Report which on-chip SRAM a port run touched, from ot_emu --touch-map.

USB AUDIO OUT (image 99 on) keeps its EP3 OUT dTDs and packet buffers in
the top 1 KB of SRAM, 0x80007c00..0x80007fff (modules/usbaudio-out/
usbaudio_out.s SRAM_*). This checks that nothing else touches that range
in a run -- best with a real, busy project, the one the unit plays:

  OT_PROJECT=<dir> python3 tools/verify/verify_set.py usb-io \\
      --extra "--touch-map 0x80000000,0x8000=out/sram_touch.bin"
  python3 tools/verify/sram_census.py out/sram_touch.bin

Each byte of the map: bit 0 = read, bit 1 = written, during the run. Only
the CPU and the port's modelled DMA are seen; a run proves what it ran,
not every path the firmware has.
"""
import sys

BASE, OURS, SIZE = 0x80000000, 0x7c00, 0x8000
STOCK_TOP = 0x7874        # the stock image's highest static SRAM use ends here (0x80007574 + 768)


def runs(t, lo, hi, minlen=256):
    out, s = [], None
    for i in range(lo, hi):
        if t[i] == 0:
            s = i if s is None else s
        else:
            if s is not None and i - s >= minlen:
                out.append((s, i))
            s = None
    if s is not None and hi - s >= minlen:
        out.append((s, hi))
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "out/sram_touch.bin"
    t = open(path, "rb").read()[:SIZE]
    used = sum(1 for b in t if b)
    print(f"{path}: {used} of {len(t)} SRAM bytes touched")
    print("untouched runs of 256 B or more:")
    for s, e in runs(t, 0, len(t)):
        print(f"  {BASE + s:#010x}..{BASE + e - 1:#010x}  {e - s} B")
    top = max((i for i in range(OURS) if t[i]), default=0)
    print(f"highest touched byte below USB AUDIO OUT's range: {BASE + top:#010x}")
    margin = [i for i in range(STOCK_TOP, OURS) if t[i]]
    if margin:
        print(f"FAIL: {len(margin)} byte(s) touched between the stock top ({BASE + STOCK_TOP:#x}) and 0x80007c00,"
              f" first {BASE + margin[0]:#x}: the margin is not free")
        return 1
    print(f"OK: nothing touched between {BASE + STOCK_TOP:#x} and 0x80007c00")
    return 0


if __name__ == "__main__":
    sys.exit(main())
