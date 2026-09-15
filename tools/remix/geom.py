"""Per-placement lines in a DSP source: `; @B` and `; @DEV`.

BusDelay's line geometry differs by where the build places it. Shipping
(payload B, core 1) has two 32K lines -- LineL the shared half
Y:0x38000-0x3FFFF, LineR the core's private FX2 buffer region Y:0x4000-0xBFFF,
which nothing else on core 1 writes (measured under the port, 15 Sep 2026)
-- for 741 ms of TIME. The DEV hatch puts the delay in payload A beside the
reverb, whose tank owns that private region, so there it keeps the two 16K
lines in the shared half (371 ms). A line ending `; @B` is kept only in the
shipping build, one ending `; @DEV` only under DEV=1; everything else is
common. The pricer selects the shipping set.
"""
import re

_TAG = re.compile(r";\s*@(B|DEV)\s*$")


def select(src: str, dev: bool) -> str:
    keep = "DEV" if dev else "B"
    out = []
    for line in src.split("\n"):
        m = _TAG.search(line)
        if m and m.group(1) != keep:
            continue
        out.append(line)
    return "\n".join(out)


def census(src: str) -> tuple[int, int]:
    """(@B lines, @DEV lines)."""
    b = sum(1 for l in src.split("\n") if _TAG.search(l) and _TAG.search(l).group(1) == "B")
    d = sum(1 for l in src.split("\n") if _TAG.search(l) and _TAG.search(l).group(1) == "DEV")
    return b, d
