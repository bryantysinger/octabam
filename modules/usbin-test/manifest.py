"""USB IN TEST -- the ColdFire -> DSP path for inputs A-D, with a test
pattern standing in for USB audio. Overrides the jacks on core 0.

Not a USB feature yet: no OUT endpoint, no host audio. It proves the
transport the USB input will use (Bryan T, 26 Sep 2026; plan in the
project's usb-audio-main-cue-plan.md, sections 3b and 4a).

ColdFire (a cave, `inject_cave.s`): state 7 of the frame transfer machine
(0x40004bc0) first sends one more transfer -- 128 halfwords, eDMA ch 0
programmed as states 4/5 program it, to core 0 at command $6320 -- and on
that DMA's completion runs stock state 7. The DSP's host handler masks
$6320 into the idle bank ($2320 or $4320).

DSP (pokes into payload A only; payload B has no ESAI):
  * P:0x88 `move r2,x:>$204` -> `jsr >$aa8`; the routine replays it.
  * P:0xaa8.. (SPATIALIZER's first 19 words) <- rx_inject.asm: copies the
    working bank's +$320 (written the frame before) over the RX block at
    x:$202, 64 samples, 24 bits from two halfwords. Everything downstream
    (GAIN, NOISE GATE, DIR, the recorder ring, core B) then sees it.
  * Dispatch id 0x05 (SPATIALIZER) init/proc -> NONE's (P:0x7c8/0x7c9) in
    payload A, so a project that selects SPATIALIZER runs NONE, not this.
    The remix lists SPATIALIZER on neither chooser.

Measured before writing (stock 1.40C under the port, no card): bank
offsets $320..$3fe have no writer after the DSP loader's boot clear;
$3ff is written every frame by the read-back unpack.

Every DSP instruction form here has a stock precedent in payload A.
"""

from remix.schema import CavePatch, Kind, Module

# ---- ColdFire cave ---------------------------------------------------------
STATE7_HOOK = 0x40004BC0
STATE7_STOCK = bytes.fromhex("7201" "13c1fc04801d")   # moveq #1,d1 ; move.b d1,0xfc04801d

# m68k-linux-gnu-as -mcpu=5475 inject_cave.s ; objcopy -O binary (492 bytes)
CAVE_BYTES = bytes.fromhex(
    "41fa00dad1fc080000004a10660000c210bc00014feffff448d7001c24280004"
    "5282214200040282000000ffe18ae98a43e80010700072002601e18be18be98b"
    "86822800e18c86840083000000a52803e08c32c40283000000ff32c352817804"
    "b2846dd452807810b0846dca4cd7001c4fef000c420013c0fc0a400c724023c1"
    "fc04500843e8001023c9fc045000303c008133c020000000323c632033c12000"
    "001c303c007f33c02000001c323c008833c120000004303c800433c0fc045014"
    "33c0fc04501c420113c1fc04401e4e754210720113c1fc04801d4e7500000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000")

# ---- DSP pokes, payload A --------------------------------------------------
# Image vaddr of a DSP word = record image address + (word - record base) * 3
# (tools/build/dsp_modmap.py). Words are little-endian 24-bit.
P_RECORD_40 = 0x400EF680      # P:0x00040, 544 words
P_RECORD_AA8 = 0x400F1771     # P:0x00aa8, 261 words (SPATIALIZER)
X_RECORD_215 = 0x400E2345     # X:0x00215, 64 words (init table, proc table)


def _w24(v):
    return bytes((v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF))


HOOK_VA = P_RECORD_40 + (0x88 - 0x40) * 3
HOOK_STOCK = _w24(0x627000) + _w24(0x000204)          # move r2,x:>$204
HOOK_WRITE = _w24(0x0BF080) + _w24(0x000AA8)          # jsr >$aa8

INJECT_VA = P_RECORD_AA8
# dsp_asm -in rx_inject.asm -org aa8 (19 words), audited with dsp56kDisassemble
INJECT_WORDS = bytes.fromhex(
    "00706204020000ce22c0400120030000d02100f061020200804006b90a0000d8"
    "56101d0c00852100d856c64001ff00006000200059540c0000")
SPAT_STOCK_HEAD = bytes.fromhex(
    "00002585070285170200f064130200c53702853f0200e444c40f020c00000300"
    "200aa40500802f9e3f02c54001a200000314058041011b0020")   # P:0xaa8..0xaba, stock


ID5_INIT_VA = X_RECORD_215 + 0x05 * 3
ID5_PROC_VA = X_RECORD_215 + (32 + 0x05) * 3

POKES = (
    ("P:0x88 dispatcher -> jsr inject", HOOK_VA, HOOK_STOCK, HOOK_WRITE),
    ("P:0xaa8 inject routine (SPATIALIZER words)", INJECT_VA, SPAT_STOCK_HEAD, INJECT_WORDS),
    ("id 0x05 init -> NONE", ID5_INIT_VA, _w24(0x000AA8), _w24(0x0007C8)),
    ("id 0x05 proc -> NONE", ID5_PROC_VA, _w24(0x000AB2), _w24(0x0007C9)),
)
assert len(INJECT_WORDS) == len(SPAT_STOCK_HEAD) == 57


def emit_pokes(_addr):
    return b"", tuple((addr, expect, write) for _l, addr, expect, write in POKES)


MODULE = Module(
    name="usbin-test",
    key="USB IN TEST",
    kind=Kind.CF_PATCH,
    doc="Test: ColdFire sends a pattern to core 0 each frame; the DSP "
        "overwrites inputs A-D with it (jacks overridden). Takes "
        "SPATIALIZER's words in payload A.",
    cf_patches=(
        CavePatch(
            label="usb in test: state-7 transfer to $6320",
            cave_addr=None,
            pinned=CAVE_BYTES,
            source="modules/usbin-test/inject_cave.s",
            hook_addr=STATE7_HOOK,
            hook_stock=STATE7_STOCK,
            report_note=" (128 halfwords -> core 0 idle bank + $320)",
        ),
        CavePatch(
            label="usb in test: DSP inject (payload A pokes)",
            cave_addr=0x400D2000,     # never written; pokes carry the addresses
            pinned=b"",
            emit=emit_pokes,
            report_note=" (P:0x88 hook, P:0xaa8 routine, id 5 -> NONE)",
        ),
    ),
)
