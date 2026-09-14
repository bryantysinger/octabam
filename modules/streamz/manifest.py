"""Streamz -- a Streams-flavoured lowpass gate.

A per-track insert with no buffer. The track's own level drives an envelope
follower, and the envelope opens a filter and an amplifier together (the
Buchla lowpass gate Streams models with a vactrol): quiet material is dark
and quiet, loud transients bright and loud, the recovery sluggish.

MODE picks how the envelope is spent: LPG (filter and amp together, the
vactrol), VCF (filter only -- an envelope filter / auto-wah), VCA (amp only
-- a plain dynamics gate).

SENS=0 leaves the envelope shut, so with MIX up the effect is a gate that
never opens; MIX=0 is an exact passthrough.
"""

from remix.schema import (BusRole, DspSection, Formatter, Harness, Kind,
                          MenuEntry, Module, Param, YBase)

_PLAIN = Formatter.PLAIN
_STEP = Formatter.STEPPED

MODULE = Module(
    name="streamz",
    key="STREAMZ",
    kind=Kind.DSP_EFFECT,
    doc="Streams-style insert: vactrol lowpass gate, LPG/VCF/VCA.",
    menu=MenuEntry(
        fx2_id=0x0e,
        donor_desc=0x400d58b8,        # DARK REV, the standing donor
        abbr=b"STRM",
        fullname=b"Streamz",
        build_tag=True,
    ),
    params=(
        # ---- page 1 -------------------------------------------------------
        # SENS drives the follower. 64 is roughly unity: a signal peaking at
        # full scale opens the gate fully.
        Param(b"SENS", 64, active=True, formatter=_PLAIN,
              doc="follower sensitivity; 64 ~ unity (full-scale peaks open it fully)"),
        # FALL is the vactrol's release; attack is fixed and fast.
        Param(b"FALL", 50, active=True, formatter=_PLAIN,
              doc="vactrol release -- short is plucky, long is a slow swell"),
        # COLR is how dark the gate gets when closed: 0 shut and silent,
        # higher leaves the filter partly open.
        Param(b"COLR", 10, active=True, formatter=_PLAIN,
              doc="how dark the gate gets when closed; 0 = fully shut and silent"),
        Param(b"MIX", 127, active=True, formatter=_PLAIN,
              doc="dry/wet; 0 = exact passthrough"),
        Param(), Param(),
        # ---- page 2 -------------------------------------------------------
        Param(),
        Param(b"MODE", 0, 3, active=True, formatter=_STEP,
              labels=("LPG", "VCF", "VCA"),
              doc="LPG = filter+amp together; VCF = envelope filter; VCA = gate only"),
        Param(), Param(), Param(), Param(),
    ),
    dsp=DspSection(
        asm="modules/streamz/streamz_lpg.asm",
        priority=9,                   # after nimbus
        bus_role=BusRole.NONE,
        ybase=YBase.NEVER,            # no buffers of any kind
        r7_latch_slot=None,
        gate_label=None,
    ),
    harness=Harness(layout_char="G", is_server=False),
)
