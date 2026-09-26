"""USB AUDIO OUT -- four channels from the host standing in for inputs A-D.

The host streams AudioStreaming interface 5 alt 1 on EP3 OUT: isochronous,
asynchronous with IMPLICIT feedback (EP3 IN, the input stream, is the
feedback source: EP1 mass storage, EP2 USB MIDI and EP3 IN leave no endpoint
for an explicit one), 4 ch x 24-bit in 4-byte subslots, <= 192 B every
250 us. Host channels 1-4 = inputs A-D.

  Descriptors: USB MIDI's descriptor unit adds the host -> device path when
    this key is in the remix (modules/usbmidi/descriptors.py): USB streaming
    IT 0x13 -> line OT 0x14 on the one clock, and interface 5. Step 1,
    26 Sep 2026: macOS lists 20 in / 4 out, 44.1 kHz, 24-bit (Bryan T's Mac).
  ColdFire (DRAM unit `usbaudio_out`, usbaudio_out.s): SET_INTERFACE(5) at
    0x4001dd0a, where usbaudio's shim sends every interface but 4; and state
    7 of the frame transfer machine (0x40004bc0): EP3 OUT up/down, four
    queued dTDs retired into a 1,024-frame ring, and once per frame one more
    host-port transfer of 128 halfwords to core 0 at $6320 (the idle bank +
    $320). Bit 8 of the first low halfword is the stream flag.
  DSP (pokes, payload A only; payload B has no ESAI): P:0x88 -> jsr >$aa8;
    P:0xaa8.. (SPATIALIZER's first 24 words) = rx_inject.asm, which copies
    the words over the RX block while the flag is set and otherwise leaves
    the jacks; dispatch id 5 -> NONE, so a project that selects SPATIALIZER
    runs NONE. The remix lists SPATIALIZER on neither chooser.
  usbaudio.s touches only ENDPTCTRL3's TX half, so EP3 IN's bring-up and
    teardown do not switch EP3 OUT off.

Needs USB MIDI and USB AUDIO. Conflicts with USB IN TEST (the same hook and
pokes): a remix carries one or the other.
"""
from remix.schema import CavePatch, Detour, Kind, Linked, Module

H = bytes.fromhex

# ---- DSP pokes, payload A (the addresses usbin-test verified) --------------
P_RECORD_40 = 0x400EF680      # P:0x00040, 544 words
P_RECORD_AA8 = 0x400F1771     # P:0x00aa8, 261 words (SPATIALIZER)
X_RECORD_215 = 0x400E2345     # X:0x00215, 64 words (init table, proc table)


def _w24(v):
    return bytes((v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF))


HOOK_VA = P_RECORD_40 + (0x88 - 0x40) * 3
HOOK_STOCK = _w24(0x627000) + _w24(0x000204)          # move r2,x:>$204
HOOK_WRITE = _w24(0x0BF080) + _w24(0x000AA8)          # jsr >$aa8

# dsp_asm -in rx_inject.asm -org aa8 (24 words), audited with dsp56kDisassemble
INJECT_WORDS = bytes.fromhex(
    "00706204020000ce22c0400120030000d021de0002c640010001004a100d0e00"
    "0000f061020200804006be0a0000d856101d0c00852100d856c64001ff000060"
    "00200059540c0000")
SPAT_STOCK_HEAD = bytes.fromhex(
    "00002585070285170200f064130200c53702853f0200e444c40f020c00000300"
    "200aa40500802f9e3f02c54001a200000314058041011b00208e3f02cf370200"
    "013d9f0e02a11c0c")   # P:0xaa8..0xabf, stock

POKES = (
    ("P:0x88 dispatcher -> jsr inject", HOOK_VA, HOOK_STOCK, HOOK_WRITE),
    ("P:0xaa8 inject routine (SPATIALIZER words)", P_RECORD_AA8, SPAT_STOCK_HEAD, INJECT_WORDS),
    ("id 0x05 init -> NONE", X_RECORD_215 + 0x05 * 3, _w24(0x000AA8), _w24(0x0007C8)),
    ("id 0x05 proc -> NONE", X_RECORD_215 + (32 + 0x05) * 3, _w24(0x000AB2), _w24(0x0007C9)),
)
assert len(INJECT_WORDS) == len(SPAT_STOCK_HEAD) == 72


def emit_pokes(_addr):
    return b"", tuple((addr, expect, write) for _l, addr, expect, write in POKES)


MODULE = Module(
    name="usbaudio-out", key="USB AUDIO OUT", kind=Kind.CF_PATCH,
    doc="Four channels from the host into inputs A-D (UAC2 EP3 OUT, implicit feedback); the jacks while the stream is closed. Takes SPATIALIZER's words on payload A.",
    linked=(Linked("usbaudio_out", "modules/usbaudio-out/usbaudio_out.s", cpu="5475", dram=True),),
    detours=(
        Detour(0x4001dd0a, H("008000400040"), "usbaudio_out", "out_setiface_shim",
               "SET_INTERFACE: interface 5 records the alt and ACKs; the rest goes on to stock"),
        Detour(0x40004bc0, H("720113c1fc04801d"), "usbaudio_out", "out_state7_shim",
               "frame transfer state 7: EP3 OUT, the ring, and one more transfer to core 0 at $6320",
               pad_to=8),
        Detour(0x4001de6e, H("23c0fc0b01c0"), "usbaudio_out", "out_ctrl_shim",
               "EP0 stall store: vendor GET 0x56 answers the OUT counters instead"),
    ),
    cf_patches=(
        CavePatch(
            label="usb audio out: DSP inject (payload A pokes)",
            cave_addr=0x400D2000,     # never written; pokes carry the addresses
            pinned=b"",
            emit=emit_pokes,
            report_note=" (P:0x88 hook, P:0xaa8 routine with the stream flag, id 5 -> NONE)",
        ),
    ),
)
