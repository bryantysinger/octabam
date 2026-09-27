"""USB AUDIO IN -- four channels from the host standing in for inputs A-D.

The host streams AudioStreaming interface 5 alt 1 on EP3 OUT: isochronous,
asynchronous with IMPLICIT feedback (EP3 IN, the input stream, is the
feedback source: EP1 mass storage, EP2 USB MIDI and EP3 IN leave no endpoint
for an explicit one), 4 ch x 24-bit in 4-byte subslots, <= 192 B every
250 us. Host channels 1-4 = inputs A-D.

  Descriptors: USB MIDI's descriptor unit adds the host -> device path when
    this key is in the remix (modules/usb-midi/descriptors.py): USB streaming
    IT 0x13 -> line OT 0x14 on the one clock, and interface 5. It refuses a
    remix without a USB AUDIO input layout (the feedback source), and one
    with USB AUDIO MASTER (a 1 ms input stream; untested).
  ColdFire (DRAM unit `usbaudio_in`, usbaudio_in.s): SET_INTERFACE(5) at
    0x4001dd0a, where usbaudio's shim sends every interface but 4; and state
    7 of the frame transfer machine (0x40004bc0): EP3 OUT up/down, four
    queued dTDs retired into a 1,024-frame ring, and once per frame one more
    host-port transfer of 128 halfwords to core 0 at $6320 (the idle bank +
    $320). Bit 8 of the first low halfword is the stream flag.
  DSP (pokes, payload A only; payload B has no ESAI): P:0x88 -> jsr >$aa8;
    P:0xaa8.. (SPATIALIZER's first 24 words) = rx_inject.asm, which copies
    the words over the RX block while the flag is set and otherwise leaves
    the jacks; dispatch id 5 -> NONE, so a project that selects SPATIALIZER
    runs NONE. A remix carrying this lists SPATIALIZER on neither chooser.
  usbaudio.s touches only ENDPTCTRL3's TX half, so EP3 IN's bring-up and
    teardown do not switch EP3 OUT off.

Needs USB MIDI and one of USB AUDIO EXTENDED, FULL or MC. Bryan T, 26 Sep
2026, as USB AUDIO OUT on usbin-test; renamed for the unit's point of view.
README.md.
"""
from remix.schema import Category, Detour, Gate, Kind, Linked, Module, Poke, Proof

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
assert len(INJECT_WORDS) == len(SPAT_STOCK_HEAD) == 72

MODULE = Module(
    name="usb-audio-in", key="USB AUDIO IN", kind=Kind.CF_PATCH,
    category=Category.MIDI_USB, author="bryantysinger", author_url="https://github.com/bryantysinger",
    proof=Proof.HARDWARE, proof_note="Bryan T's MKII, build 16 (usb-io, beside USB AUDIO MC), 27 Sep 2026; `verify_usb_in` under the port",
    doc="Four channels from the host into inputs A-D (UAC2 EP3 OUT, implicit feedback); the jacks while the stream is closed. Takes SPATIALIZER's words on payload A.",
    linked=(Linked("usbaudio_in", "modules/usb-audio-in/usbaudio_in.s", cpu="5475", dram=True),),
    detours=(
        Detour(0x4001dd0a, H("008000400040"), "usbaudio_in", "in_setiface_shim",
               "SET_INTERFACE: interface 5 records the alt and ACKs; the rest goes on to stock"),
        Detour(0x40004bc0, H("720113c1fc04801d"), "usbaudio_in", "in_state7_shim",
               "frame transfer state 7: EP3 OUT, the ring, and one more transfer to core 0 at $6320",
               pad_to=8),
        Detour(0x4001de6e, H("23c0fc0b01c0"), "usbaudio_in", "in_ctrl_shim",
               "EP0 stall store: vendor GET 0x56 answers the IN counters instead"),
    ),
    pokes=(
        Poke(HOOK_VA, HOOK_STOCK, HOOK_WRITE, "P:0x88 dispatcher -> jsr inject (payload A)"),
        Poke(P_RECORD_AA8, SPAT_STOCK_HEAD, INJECT_WORDS, "P:0xaa8 inject routine, over SPATIALIZER's first 24 words (payload A)"),
        Poke(X_RECORD_215 + 0x05 * 3, _w24(0x000AA8), _w24(0x0007C8), "id 0x05 init -> NONE (payload A)"),
        Poke(X_RECORD_215 + (32 + 0x05) * 3, _w24(0x000AB2), _w24(0x0007C9), "id 0x05 proc -> NONE (payload A)"),
    ),
    requires=("USB MIDI",),
    gates=(Gate("tools/verify/verify_usb_in.py", remix_arg=False, venv=True, stage="image"),),
)
