"""TEMPO BUS -- the TEMPO window carries the bus engines' knobs.

The TEMPO key opens the stock TEMPO window at the menu window's size
(118 x 64) with a stock-style settings screen in place of its big-digit
draw: the header ("TMP 121.2" at the left, then a key: "NAV", the
four arrows, "A" and the font's knob glyph; the rule) and two titled boxes, DELAY and
REVERB, listing each engine's named parameters with the values its own
formatters print. UP/DOWN move the cursor in the focused box, A (or B)
edits (x7 while pushed, as stock),
LEFT / RIGHT switch boxes (each keeps its own cursor); a mode's
"---" slots are left out of the list. C-F are held while the window is open. LEVEL
steps whole BPM (the stock 0x4004b918) and 0.1 BPM with FUNC held (the
stock step 0x4004b824(0, +-1) that UP/DOWN made). YES/NO/TEMPO (close) keep the
stock window's handlers (layer 0x400bb4ec).

Stock routines used, all as the CONTROL INPUT (0x40065674) and MIDI SYNC
(0x4006730c) screens call them: header text 0x40012bd8 / width
0x40012f30 in font 0x400ba876, rule 0x40011910, titled
box 0x4007efd0, invert bar 0x40012254. Input: an extra layer pushed by
0x40031494 over TEMPO's and popped by 0x4003146c. Edits: page 1 through
the page-1 writer 0x40054cd8(track, 24 + slot, value); page 2 with the
FX2 page-2 editor's stores (Part +0x8f084, shadow 0x100a51d2, live lane
+0x38, the four dirty flags; CC MAP's write path), then MODE DEFAULTS'
CC_MODEDEF2 when that module is linked before this one.

Measured under the port: the stock TEMPO window, CONTROL INPUT and MIDI
SYNC drawn from memory dumps (`--mem-dump` of the window planes). The
screen itself: see the PR.
"""

from remix.schema import Detour, Kind, Linked, Module, Poke

H = bytes.fromhex
ENGINES = ("DELAY SERVER", "REVERB SERVER")    # box 0, box 1


def table_inc(modules):
    """ENGIDS (the two FX2 ids) and NAMED (per box, a bit per slot the
    engine's manifest names). The screen lists a named slot while its
    current name is not the mode's "---". An engine not in the remix has
    no rows."""
    ids, masks = [], []
    for key in ENGINES:
        m = modules.get(key)
        named = [i for i, p in enumerate(m.params) if p.name] if m is not None else []
        ids.append(m.menu.fx2_id if m is not None else 0xff)
        masks.append(sum(1 << i for i in named))
    return ("ENGIDS: .byte   " + ", ".join(map(str, ids)) + "\n"
            "        .even\n"
            "NAMED:  .word   " + ", ".join(f"{m:#x}" for m in masks) + "\n")


MODULE = Module(
    name="tempo-bus",
    key="TEMPO BUS",
    kind=Kind.CF_PATCH,
    doc="The TEMPO window lists and edits BusDelay's and BusVerb's knobs "
        "(UP/DOWN = row, A or B = value, LEFT/RIGHT = engine, FUNC + LEVEL = 0.1 BPM).",
    # Both pinned in measured free runs (docs/remixer/PLACEMENT.md): the
    # helpers (host lookup, value read/write) at the start of the overflow
    # run 0x400d24d0..0x400d2ce0 (the floating caves that overflow the
    # clone window take the run after them), the screen in the first
    # part of 0x400d64da..0x400d6b00, below the FX2 chooser's NONE row. The
    # helpers link first: the screen calls them. (0x400d2ee6..0x400d3020 is
    # refused at placement: a live descriptor, modules/midi-scenes.)
    linked=(Linked("helpers", "modules/tempo-bus/helpers.s",
                   cave_addr=0x400D24D0, include=table_inc),
            Linked("tempobus", "modules/tempo-bus/tempobus.s",
                   cave_addr=0x400D64E0, include=table_inc),),
    detours=(
        Detour(0x40059F2C, H("4ef94004b528"), "tempobus", "tb_open",
               "TEMPO opener: push the bus layer, draw the bus screen"),
        Detour(0x4004B528, H("4e56ffe848d7041c"), "tempobus", "tb_draw",
               "TEMPO draw (every caller, BPM edits included): the bus screen",
               pad_to=8),
        Detour(0x40056930, H("4ab9460d16a0"), "tempobus", "tb_close",
               "TEMPO close: pop the bus layer, then the stock close"),
    ),
    pokes=(
        Poke(0x40059F04, H("48780030"), H("48780040"), note="TEMPO window height 48 -> 64 (the menu window's)"),
        Poke(0x40059F08, H("48780049"), H("48780076"), note="TEMPO window width 73 -> 118 (the menu window's)"),
    ),
)
