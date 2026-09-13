"""INFLATOR -- band-split waveshaper/saturator, port of RCInflator 2 (Oxford
Edition) [lewloiwc, after RCJacH/sai'ke/chmaha].

Insert, no bus role: processes its own track's audio in place, no shared
window, placeable on any track (both payloads). See inflator.asm's own
header for the full derivation -- filter/waveshaper formulas are numerically
checked against the float JSFX reference in sim_inflator.py (quantization
error 1e-6 to 3.7e-5 across the tested parameter range).

v1 scope, both deliberate cuts (not bugs worked around -- see inflator.asm):
CLIP is fixed on (+/-1 true throughout; the JSFX's CLIP=off / y<2 range is
out of scope for now), and INPUT trim is the JSFX's original 0.5x..1.49x
range (an earlier draft capped it to chase an overflow that turned out to
live in the filter's own arithmetic, not the trim knob -- see the SPLIT
note below).

Open, not yet run through dsp_host:
  - The branchless sign-select in waveshape() uses `tlt`, off a `tst` --
    I have not seen this specific instruction used anywhere in the modules
    this project shared with me (only `tne`/`teq`), so it's a plausible
    DSP56300 mnemonic rather than a confirmed-in-this-codebase one. First
    thing to check on a real assemble/run.
  - Known, accepted (not a bug): SPLIT mode can drive the summed output
    past +/-1 by a substantial margin even at default settings (measured
    up to ~0.48 over, full-scale input, CURVE at its hot extreme) -- an
    "inflator" is supposed to add loudness, and hardware will hard-limit
    it at the final store to x:(r0) the same way the OUTPUT knob exists
    to manage on the original plugin. Worth knowing before the first
    listen, not a defect to chase.
"""

from remix.schema import (BusRole, DspSection, Formatter, Harness, Kind,
                          MenuEntry, Module, Param, YBase)

MODULE = Module(
    name="inflator",
    key="INFLATOR",
    kind=Kind.DSP_EFFECT,
    doc="Band-split waveshaper/saturator (RCInflator 2 Oxford Edition port).",

    menu=MenuEntry(
        # 0x1e: free per DSP.md's id survey at the time this was written
        # (0x1d/0x1e/0x1f unclaimed). `make modules` is the actual arbiter --
        # HELLO WORLD itself had to move off 0x17 once Rungs took it, so
        # confirm this is still free before building, not just trust this
        # comment.
        fx2_id=0x1e,
        donor_desc=0x400d5726,        # SPRING REV -- both DARK REV and
                                      # SPRING REV are the same descriptor
                                      # class (400328e4, per PARAM_PAGES.md's
                                      # entry table), and this manifest
                                      # already writes an explicit Param()
                                      # for all six page-1 slots -- so the
                                      # donor's own empty slots (SPRING REV's
                                      # page 1 is TIME --- --- HP LP MIX,
                                      # positions 1/2 blank) don't matter,
                                      # nothing is inherited
        abbr=b"INFL",                 # 4 chars, fits the 5-byte field with
                                      # its terminator (see HELLO WORLD's
                                      # README for what happens if it doesn't)
        fullname=b"INFLATOR",         # 8 of 12 usable bytes
        build_tag=False,
    ),

    params=(
        # ---- page 1: the four knobs (the two selects moved to page 2, 13 Sep 2026)
        Param(b"INPUT", 64, 128, active=True, formatter=Formatter.PLAIN,
              doc="input trim, ~0.5x..1.49x (linear taper; see header for "
                  "the LUT); 64 = unity"),
        Param(b"EFFECT", 0, 128, active=True, formatter=Formatter.PLAIN,
              doc="wet/dry, 0=dry .. 127=fully wet (JSFX default is dry)"),
        Param(b"CURVE", 64, 128, active=True, formatter=Formatter.PLAIN,
              doc="waveshaper character, bipolar around 64 (JSFX -50..50)"),
        Param(b"OUTPUT", 127, 128, active=True, formatter=Formatter.PLAIN,
              doc="output trim, 0..~0.99x (linear taper); 127 = ~0dB"),
        Param(), Param(),   # page 1 slots 4-5 blank: a SELECT may not sit on page 1 (the
                            # tick widget has never been drawn there: schema, verify_menu)
        # ---- page 2: knob . select . knob . select . knob . select ----------
        Param(),
        Param(b"CLIP", 1, 2, active=True, formatter=Formatter.STEPPED,
              labels=("OFF", "ON"),
              doc="v1: always effectively on (+/-1 true); CLIP=off's "
                  "+/-2 range not yet implemented"),
        Param(),
        Param(b"SPLIT", 0, 2, active=True, formatter=Formatter.STEPPED,
              labels=("OFF", "ON"),
              doc="band-split (240/2400 Hz fixed) waveshaping vs single-band"),
        Param(), Param(),
    ),

    dsp=DspSection(
        asm="modules/inflator/inflator.asm",
        # Arbitrary, after HELLO WORLD's 11 -- BYTE-LOAD-BEARING once this
        # sits in a real remix alongside other modules, so check the ledger
        # rather than trusting this number if it collides.
        priority=12,
        bus_role=BusRole.NONE,
        ybase=YBase.NEVER,            # no absolute Y anywhere in the source
        r7_latch_slot=None,           # init: unconditionally zeros the 4
                                      # filter-state words every time the
                                      # effect is (re)selected -- no warm-up
                                      # tag scheme needed, unlike the bus
                                      # servers (see FAILURE_MODES.md's
                                      # warm-up-tag entry, which does not
                                      # apply here for that reason)
        gate_label=None,
    ),

    # "X" -- "I" (my original pick) turned out to collide with stock LO-FI's
    # own letter in tools/remix/stock.py, which I had no visibility into
    # when I chose it; confirmed free against BOTH modules/*/manifest.py
    # and stock.py's full letter list before landing on X.
    harness=Harness(layout_char="X", is_server=False),
)
