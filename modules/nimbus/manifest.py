"""Nimbus -- a Clouds-flavoured granular texture insert.

A per-track insert with a real buffer: the track's audio records
continuously into a 32,768-word mono line (743 ms) and four unity-rate
grains read it back, two per channel at half-period offsets so each
channel's triangle windows sum to constant power. POS reaches back into the
buffer, SIZE picks the grain length (23/46/93/186 ms), DENS scatters each
grain's start by up to ~92 ms (latched at the grain's own wrap), FRZE stops
the write head so the last 743 ms becomes a frozen cloud.

One Nimbus per core: the buffer is the fixed core-private FX2-instance
region Y:0x4000-0xBFFF, the ground BusVerb's tank uses. Two instances on
one core would share one buffer, as would a buffer-writing stock FX2 on
the same core.

MIX=0 is an exact passthrough (during warm-up the effect outputs pure dry).
"""

from remix.schema import (BusRole, Claims, DspSection, Formatter, Harness,
                          Kind, MenuEntry, Module, Param, YBase)

_PLAIN = Formatter.PLAIN
_STEP = Formatter.STEPPED

MODULE = Module(
    name="nimbus",
    key="NIMBUS",
    kind=Kind.DSP_EFFECT,
    doc="Clouds-style insert: 743 ms granular texture, 4 grains, freeze.",
    menu=MenuEntry(
        fx2_id=0x1a,
        donor_desc=0x400d58b8,        # DARK REV, the standing donor
        abbr=b"NMBS",
        fullname=b"Nimbus",
        build_tag=True,
    ),
    params=(
        # ---- page 1 -------------------------------------------------------
        Param(b"POS", 30, active=True, formatter=_PLAIN,
              doc="how far back into the 743 ms buffer the grains read"),
        Param(b"SIZE", 70, active=True, formatter=_PLAIN,
              doc="grain length, 23/46/93/186 ms"),
        Param(b"DENS", 40, active=True, formatter=_PLAIN,
              doc="per-grain start scatter, up to ~92 ms -- 0 is coherent, high is cloud"),
        Param(b"MIX", 100, active=True, formatter=_PLAIN,
              doc="dry/wet; 0 = exact passthrough"),
        Param(), Param(),
        # ---- page 2 -------------------------------------------------------
        Param(),
        Param(b"FRZE", 0, 2, active=True, formatter=_STEP,
              labels=("RUN", "HOLD"),
              doc="stop the write head -- the last 743 ms becomes a frozen cloud"),
        Param(), Param(), Param(), Param(),
    ),
    dsp=DspSection(
        asm="modules/nimbus/nimbus_grain.asm",
        priority=8,                   # after rungs
        bus_role=BusRole.NONE,
        ybase=YBase.NEVER,            # the buffer is core-private Y, no $30000
        r7_latch_slot=None,
        gate_label=None,
    ),
    # The 743 ms line is hardcoded into Y:0x4000-0xBFFF, the per-core region
    # BusVerb's tank uses: the two cannot share a core.
    claims=Claims(owns_fx2_buffers=True),
    harness=Harness(layout_char="N", is_server=False),
)
