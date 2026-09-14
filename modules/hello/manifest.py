"""HELLO WORLD -- a linear volume knob, the reference minimal insert.

One page-1 knob (GAIN), out = in * GAIN/128, processed in place per the
insert contract. The worked example of manifest + engine + render gates
that _template describes, kept buildable as the DSP pipeline's canary.

GAIN >= 127 takes an early-out before any arithmetic, so 127 is a bit-exact
passthrough; GAIN=0 is exact silence. Both are render gates. The cost of
the exact top: 126 -> 127 steps 0.984 -> 1.0 (~0.14 dB).
"""

from remix.schema import (BusRole, DspSection, Formatter, Harness, Kind,
                          MenuEntry, Module, Param, YBase)

MODULE = Module(
    name="hello",
    key="HELLO WORLD",
    kind=Kind.DSP_EFFECT,
    doc="Reference minimal insert: one GAIN knob, out = in * GAIN/128.",

    menu=MenuEntry(
        # Not one of stock's ids (schema.STOCK_FX2_IDS) and claimed by no
        # other module; the registry refuses a duplicate at import.
        fx2_id=0x1b,
        donor_desc=0x400d58b8,        # DARK REV
        abbr=b"HELO",                 # <=4 chars: the 5-byte field keeps its NUL
        fullname=b"HELLO WORLD",      # 11 of 13 bytes
        build_tag=False,
    ),

    params=(
        # ---- page 1 -------------------------------------------------------
        Param(b"GAIN", 127, 128, active=True, formatter=Formatter.PLAIN,
              doc="linear level, out = in x GAIN/128; 127 exact pass, 0 silence"),
        Param(), Param(), Param(), Param(), Param(),
        # ---- page 2: none ---------------------------------------------------
        Param(), Param(), Param(), Param(), Param(), Param(),
    ),

    dsp=DspSection(
        asm="modules/hello/gain.asm",
        priority=11,                  # byte-load-bearing
        bus_role=BusRole.NONE,
        ybase=YBase.NEVER,            # no absolute Y anywhere in the source
        r7_latch_slot=None,
        gate_label=None,
    ),

    harness=Harness(layout_char="H", is_server=False),
)
