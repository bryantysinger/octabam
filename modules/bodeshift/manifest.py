"""BodeShift -- a Warps-flavoured Bode frequency shifter.

A per-track insert with no buffer. Every partial moves by the same number
of hertz, so harmonic relationships are not preserved: small shifts give
slow metallic phasing and detune, large ones clangorous inharmonic
material. A ring modulator makes both sidebands; this cancels one, using a
Hilbert pair of allpass chains.

MODE picks UP, DOWN, or WIDE (up on the left channel and down on the right,
so the two directions beat against each other across the stereo field).
FDBK sends the shifted output back in, so each pass shifts again and partials
walk up or down the spectrum in a spiral -- the classic Bode barber-pole.

MIX=0 is an exact passthrough.
"""

from remix.schema import (BusRole, DspSection, Formatter, Harness, Kind,
                          MenuEntry, Module, Param, YBase)

_PLAIN = Formatter.PLAIN
_STEP = Formatter.STEPPED

MODULE = Module(
    name="bodeshift",
    key="BODESHIFT",
    kind=Kind.DSP_EFFECT,
    doc="Warps-style insert: Bode frequency shifter, UP/DOWN/WIDE + feedback.",
    menu=MenuEntry(
        fx2_id=0x0f,
        donor_desc=0x400d58b8,        # DARK REV, the standing donor
        abbr=b"BODE",
        fullname=b"BodeShift",
        build_tag=True,
    ),
    params=(
        # ---- page 1 -------------------------------------------------------
        # FREQ 0 with FINE 0 is a shift of zero, a near bypass.
        Param(b"FREQ", 0, active=True, formatter=_PLAIN,
              doc="coarse shift in Hz -- every partial moves by the same amount"),
        Param(b"FINE", 20, active=True, formatter=_PLAIN,
              doc="fine shift -- small values give slow metallic phasing"),
        Param(b"FDBK", 0, active=True, formatter=_PLAIN,
              doc="feedback -- each pass shifts again: the Bode barber-pole spiral"),
        Param(b"MIX", 100, active=True, formatter=_PLAIN,
              doc="dry/wet; 0 = exact passthrough"),
        Param(), Param(),
        # ---- page 2 -------------------------------------------------------
        Param(),
        Param(b"MODE", 2, 3, active=True, formatter=_STEP,
              labels=("UP", "DOWN", "WIDE"),
              doc="shift direction; WIDE goes up-left / down-right and beats in stereo"),
        Param(), Param(), Param(), Param(),
    ),
    dsp=DspSection(
        asm="modules/bodeshift/bode_shift.asm",
        priority=10,                  # after streamz
        bus_role=BusRole.NONE,
        ybase=YBase.NEVER,            # no buffers of any kind
        r7_latch_slot=None,
        gate_label=None,
    ),
    harness=Harness(layout_char="B", is_server=False),
)
