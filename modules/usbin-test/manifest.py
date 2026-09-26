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

Test signal: four -20 dBFS sines, A 440, B 660, C 880, D 1100 Hz (DSP slots
2, 3, 0, 1), phase-continuous. The buffer is in the cave, written and
DMA'd only through the uncached alias, with its cached lines pushed once
(`cpushl dc`) on the first run.

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

# m68k-linux-gnu-as -mcpu=5475 inject_cave.s ; objcopy -O binary (1,568 bytes)
CAVE_BYTES = bytes.fromhex(
    "41fa04fed1fc080000004a280001662043fa04ee20090280fffffff022407013"
    "f46943e90010538066f6117c000100014a10660000aa10bc00014fefffe848d7"
    "1c1c43e8002049fa00b4701045e8001047fa009a72042412d49b24c27818e8aa"
    "26342c002803e08432c40283000000ff32c3538166e0538066d24cd71c1c4fef"
    "0018420013c0fc0a400c724023c1fc04500843e8002023c9fc045000303c0081"
    "33c020000000323c632033c12000001c303c007f33c02000001c323c008833c1"
    "20000004303c800433c0fc04501433c0fc04501c420113c1fc04401e4e754210"
    "720113c1fc04801d4e750000051bbf730662af50028ddfb903d4cf9600000000"
    "0000506b0000a0c90000f10e0001412f0001911e0001e0ce0002303500027f46"
    "0002cdf300031c33000369f70003b734000403df00044fec00049b4e0004e5fa"
    "00052fe5000579030005c149000608ac00064f210006949d0006d91500071c7e"
    "00075ecf00079ffd0007dffe00081ec800085c51000898910008d37d00090d0c"
    "0009453700097bf30009b1390009e500000a1741000a47f3000a7710000aa48f"
    "000ad06b000afa9b000b231a000b49e1000b6eeb000b9231000bb3af000bd35f"
    "000bf13b000c0d41000c276a000c3fb4000c561a000c6a99000c7d2e000c8dd7"
    "000c9c8f000ca956000cb428000cbd06000cc3ec000cc8db000ccbd0000ccccd"
    "000ccbd0000cc8db000cc3ec000cbd06000cb428000ca956000c9c8f000c8dd7"
    "000c7d2e000c6a99000c561a000c3fb4000c276a000c0d41000bf13b000bd35f"
    "000bb3af000b9231000b6eeb000b49e1000b231a000afa9b000ad06b000aa48f"
    "000a7710000a47f3000a17410009e5000009b13900097bf30009453700090d0c"
    "0008d37d0008989100085c5100081ec80007dffe00079ffd00075ecf00071c7e"
    "0006d9150006949d00064f21000608ac0005c1490005790300052fe50004e5fa"
    "00049b4e00044fec000403df0003b734000369f700031c330002cdf300027f46"
    "000230350001e0ce0001911e0001412f0000f10e0000a0c90000506b00000000"
    "ffffaf95ffff5f37ffff0ef2fffebed1fffe6ee2fffe1f32fffdcfcbfffd80ba"
    "fffd320dfffce3cdfffc9609fffc48ccfffbfc21fffbb014fffb64b2fffb1a06"
    "fffad01bfffa86fdfffa3eb7fff9f754fff9b0dffff96b63fff926ebfff8e382"
    "fff8a131fff86003fff82002fff7e138fff7a3affff7676ffff72c83fff6f2f4"
    "fff6bac9fff6840dfff64ec7fff61b00fff5e8bffff5b80dfff588f0fff55b71"
    "fff52f95fff50565fff4dce6fff4b61ffff49115fff46dcffff44c51fff42ca1"
    "fff40ec5fff3f2bffff3d896fff3c04cfff3a9e6fff39567fff382d2fff37229"
    "fff36371fff356aafff34bd8fff342fafff33c14fff33725fff33430fff33333"
    "fff33430fff33725fff33c14fff342fafff34bd8fff356aafff36371fff37229"
    "fff382d2fff39567fff3a9e6fff3c04cfff3d896fff3f2bffff40ec5fff42ca1"
    "fff44c51fff46dcffff49115fff4b61ffff4dce6fff50565fff52f95fff55b71"
    "fff588f0fff5b80dfff5e8bffff61b00fff64ec7fff6840dfff6bac9fff6f2f4"
    "fff72c83fff7676ffff7a3affff7e138fff82002fff86003fff8a131fff8e382"
    "fff926ebfff96b63fff9b0dffff9f754fffa3eb7fffa86fdfffad01bfffb1a06"
    "fffb64b2fffbb014fffbfc21fffc48ccfffc9609fffce3cdfffd320dfffd80ba"
    "fffdcfcbfffe1f32fffe6ee2fffebed1ffff0ef2ffff5f37ffffaf9500000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000")

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
