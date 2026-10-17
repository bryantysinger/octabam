"""REC MATRIX (proof of concept): a recorder SRC3 value MTRX (10) that records a
sum of sources chosen per recorder, through stock's SRC3 slot.

One detour at the recorder's SRC3 select (0x400075de, inside the write path
0x400068e4): stock's `mvsb d1,d1; moveq #7,d4; cmpl d1,d4` becomes a jmp to
rmx_select, which replays them for every value but 10. For 10 it sums the
recorder's sources for the current segment into its own block and hands
stock that block as the SRC3 pointer (d5) at 0x40007648, so stock's SRC3
gain and fades, INAB/INCD, the old-content path, the saturating sum and the
pack all run unchanged. Mixing rules follow stock's INAB table (README.md).

SRC3 is stored as 0 -, 1..8 T1..T8, 9 MAIN, 10 CUE; MTRX is stored as 11
(the validator's clamp and the descriptor's count are widened for it) and
reaches the select as 10. RECORDING SETUP 1 draws it MTRX (a second detour at
the SRC3 formatter push, 0x4002fc00).

The matrix: one 16-bit mask per recorder, eight PROJECT-scope Number
settings (REC1..REC8, store octabam.rec-matrix) kept in the project's
brain.work and loaded at each project load. The mixer reads a recorder's
mask through rmx_mask_ptr (remix.inc): BRAIN's run-time value when the image
carries BRAIN, else the constant default (0, silence).

The editor (editor.s): knob E on RECORDING SETUP 1, with SRC3 on MTRX, opens
a full-screen window of all eight recorders' rows. The trigs edit the active
track's row (1 AB, 2 CD, 3 MAIN, 4 CUE, 5..8 A..D, 9..16 T1..T8; a pair and
its inputs exclude each other, the newest press wins) and show it on their
LEDs; track keys change the row; NO or knob E closes. Each edit is saved to
brain.work as a SETTINGS edit is.
"""
import os

from remix.schema import (Apply, Category, Detour, Kind, Linked, Module, Number, Poke, Proof,
                           Scope, Setting, Store, SymbolRef)

H = bytes.fromhex

SELECT_SITE = 0x400075DE
SELECT_STOCK = H("7301" "7807" "b881")              # mvsb d1,d1; moveq #7,d4; cmpl d1,d4

# Stored SRC3: 0 -, 1..8 T1..T8, 9 MAIN, 10 CUE; MTRX is stored as 11.
SRC3_COUNT = 0x400D3C74 + 0xD2 + 4 * 4                # descriptor entry 8, slot 4, u32
VALIDATOR_CMP = 0x40002CB2                             # moveq #10,d1 (SRC3 max)
VALIDATOR_SET = 0x40002CB8                             # moveq #10,d3 (written over a larger value)

SCREEN_SITE = 0x4002FC00
SCREEN_STOCK = H("2e84" "487af558")                    # move.l d4,(sp); pea pc(0x4002f15c)

# The editor (editor.s): knob E on RECORDING SETUP 1, the window's redraw,
# the trig-LED refresh and the window's close.
DRAW_SITE, DRAW_STOCK = 0x4002F2F8, H("4e56ff98" "48d73cfc")    # link fp,#-104; movem.l d2-d7/a2-a5,(sp)
LEDS_SITE, LEDS_STOCK = 0x40043FDC, H("4fefffbc" "48d73c7c")    # lea -68(sp),sp; movem.l d2-d6/a2-a5,(sp)
CLOSE_SITE, CLOSE_STOCK = 0x4002EE88, H("2f0a" "4ab9460d10cc")  # move.l a2,-(sp); tst.l 0x460d10cc
KNOB_E_MKII = 0x400BA4D4 + 9 * 0x1A + 2   # RECORDING SETUP's MKII key layer, knob E's press (0)
KNOB_E_MKI = 0x400BA60C + 9 * 0x1A + 2    # the MKI layer's

STORE = "octabam.rec-matrix"

# Mask bits: 0 A, 1 B, 2 C, 3 D, 4 AB, 5 CD, 6..13 T1..T8, 14 MAIN, 15 CUE.
# Signed 16-bit (BRAIN's Number); bit 15 (CUE) reads as negative.
SETTINGS = tuple(
    Setting(r + 1, f"REC{r + 1}", Number(-0x8000, 0x7FFF), default=0,
            scope=Scope.PROJECT, apply=Apply.LIVE,
            doc=f"recorder {r + 1}'s MTRX sources, one bit each")
    for r in range(8))


def mask_inc(mods):
    """rmx_mask_ptr: eight longs, recorder 1 first, each the address of that
    recorder's mask as a long. With BRAIN in the image they are BRAIN's
    value globals (remix.brain.value_symbol), read live; otherwise local
    constants holding the defaults."""
    from remix import brain, registry
    remix = registry.remix(os.environ.get("REMIX")) if os.environ.get("REMIX") else None
    live = {}
    if remix is not None:
        for r, s in brain.resolve(remix, mods):
            if r.store_id == STORE:
                live[r.key] = (r.runtime, int(r.value))
    out = ["        .balign 4", "        .global rmx_mask_ptr", "rmx_mask_ptr:"]
    consts = []
    for k in range(1, 9):
        runtime, value = live.get(k, (False, 0))
        if runtime:
            out.append(f"        .long   {brain.value_symbol(STORE, k)}")
        else:
            out.append(f"        .long   rmx_mask_c{k}")
            consts.append(f"rmx_mask_c{k}: .long {value}")
    return "\n".join(out + consts) + "\n"


MODULE = Module(
    name="rec-matrix", key="REC MATRIX", kind=Kind.CF_PATCH,
    category=Category.UTILITIES, author="bryantysinger", author_url="https://github.com/bryantysinger",
    proof=Proof.HARDWARE,
    proof_note=("Bryan T's unit, 17 Oct 2026: BUILD 1 (hardcoded matrix) and BUILD 2 (REC2 from the "
                "project's brain.work = A + B + T1): MTRX selected on T2 records T1 with A and B, as expected; "
                "REC2 edited in BRAIN > SETTINGS is saved to brain.work and read back on reload. A brain.work "
                "created on a Mac is not read (one the unit created and the Mac edited in place is). Under the "
                "port, 24-bit, 19,120 samples: 0.5(A+B) at gain 1.0000000 and stock's own SRC3 = T1 take, both "
                "within 1 LSB; REC2 = A records A on both sides bit for bit; no brain.work records silence"),
    doc="Recorder SRC3 = MTRX: records a per-recorder sum of inputs, tracks, MAIN and CUE, chosen per recorder and stored with the project.",
    store=Store(STORE),
    settings=SETTINGS,
    requires_brain=True,
    linked=(Linked("rmx", "modules/rec-matrix/rmx.s", dram=True, include=mask_inc),
            Linked("rmxed", "modules/rec-matrix/editor.s", dram=True)),
    detours=(Detour(SELECT_SITE, SELECT_STOCK, "rmx", "rmx_select",
                    "SRC3 select: 10 (MTRX) points the SRC3 source at the recorder's summed block",
                    kind="jmp"),
             Detour(SCREEN_SITE, SCREEN_STOCK, "rmx", "src3_screen",
                    "RECORDING SETUP 1: the SRC3 formatter push, MTRX drawn", kind="jsr"),
             Detour(DRAW_SITE, DRAW_STOCK, "rmxed", "rmx_on_draw",
                    "RECORDING SETUP's redraw: the matrix while the editor is open", kind="jmp", pad_to=8),
             Detour(LEDS_SITE, LEDS_STOCK, "rmxed", "rmx_on_leds",
                    "the trig-LED refresh: the recorder's row while the editor is open", kind="jmp", pad_to=8),
             Detour(CLOSE_SITE, CLOSE_STOCK, "rmxed", "rmx_on_close",
                    "RECORDING SETUP's close: the editor closed first", kind="jmp", pad_to=8),),
    symbol_refs=(SymbolRef(KNOB_E_MKII, 0, "rmxed", "rmx_knob_e",
                           "RECORDING SETUP (MKII layer): knob E's push opens the matrix editor"),
                 SymbolRef(KNOB_E_MKI, 0, "rmxed", "rmx_knob_e",
                           "RECORDING SETUP (MKI layer): knob E's push opens the matrix editor"),),
    pokes=(
        Poke(SRC3_COUNT, (11).to_bytes(4, "big"), (12).to_bytes(4, "big"), "SRC3 count 11 -> 12 (MTRX)"),
        Poke(VALIDATOR_CMP, H("720a"), H("720b"), "part validator: SRC3 max 10 -> 11"),
        Poke(VALIDATOR_SET, H("760a"), H("760b"), "part validator: SRC3 max 10 -> 11"),
    ),
)
