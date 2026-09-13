"""MODULATION -- one modulated line, three modes, FX1 only.

The third BamSep26 station. It REPLACES stock CHORUS (id 0x12) and covers
what stock spreads over CHORUS, FLANGER and COMB:

    CHOR  a 10 ms line swept slowly, no feedback: the classic (MIX 127 is
          vibrato: the wet alone)
    FLNG  a 0.3 ms line swept wide, with feedback: the jet
    COMB  a short line tuned by DLY with heavy feedback: a resonator

13 Sep 2026: PHSR, TREM, VIB and PAN retired (Sam). The phaser was the
pricer's dearest station loop (464 cycles/sample, two allpass chains);
tremolo and auto-pan are the OT's own LFO on AMP VOL / BAL; vibrato is CHOR
at MIX 127. A part that stored 3..6 in MODE runs CHOR (the decode matches
1 and 2 only). The freed words and cycles fund Spectrum.

⚠️ **FX1 ONLY, and it enforces that itself.** It needs a per-track delay line,
and beside the servers the only free per-track buffer is the FX1 slot: every
FX2 instance buffer is BusVerb's tank on core 0 or BusDelay's line on
tracks 3-4. It reads its base from the host's bump allocator at INIT (never
in proc -- docs/firmware/DSP.md section 10), and if that base is an FX2 slot
(>= 0x4000) it runs as a dry pass and writes NOTHING. That promise is what
`Claims(fx1_only=True)` declares and what its render gate proves.

Two lines of 1,024 words, L and R, out of the 3,072 an FX1 slot gives: 23 ms
each, enough for chorus, flanger, vibrato and a comb down to 43 Hz. The FX1
bases (0x1000 0x1c00 0x2800 0x3400) are all multiples of 1,024, but nothing
here depends on that -- the read offset is masked, not the address.

It is a BUS CLIENT on the other two stations' terms: ->DEL / ->VRB on page 1,
registration gated on each knob, and it never housekeeps.

DEFAULTS ARE A PASSTHROUGH (MIX 0), because a part that stored CHORUS runs
this after the flash. ⚠️ A part's STORED bytes are stock CHORUS's -- the
stamper (plan A6) writes ours.
"""

from remix.schema import (BusRole, Claims, DspSection, Formatter, Harness,
                          Kind, MenuEntry, ModeView, Module, Param, YBase)

_PLAIN = Formatter.PLAIN
_STEP = Formatter.STEPPED

_BLANK = Param(b"", 0)

MODULE = Module(
    name="modulation",
    key="MODULATION",
    kind=Kind.DSP_EFFECT,
    doc="BamSep26 station: chorus / flanger / comb, FX1 only.",
    menu=MenuEntry(
        fx2_id=0x12,
        replaces="CHORUS",
        donor_desc=0x400d58b8,        # DARK REV: 12 active slots, selects 7/9/11
        abbr=b"MODU",
        fullname=b"Modulation",
        build_tag=True,
    ),
    params=(
        # ---- page 1: the performance surface, scene/CC-reachable -----------
        Param(b"RATE", 40, active=True, formatter=_PLAIN,
              doc="LFO speed, ~0.05 Hz to ~8 Hz on a squared taper"),
        Param(b"DPTH", 48, active=True, formatter=_PLAIN,
              doc="how far the LFO sweeps the line"),
        Param(b"FDBK", 0, active=True, formatter=_PLAIN,
              doc="feedback around the line: the flanger's jet, the comb's ring; 0 = none"),
        Param(b"MIX", 0, active=True, formatter=_PLAIN,
              doc="dry/wet; 0 = exact passthrough, 64 = classic chorus, 127 = the wet alone (vibrato in CHOR)"),
        _BLANK,   # -DEL: the stations lost their sends in the one-aux rig (7 Sep 2026)
        _BLANK,   # -VRB: the stations lost their sends in the one-aux rig (7 Sep 2026)
        # ---- page 2: knob / select / knob / select / knob / select ----------
        Param(b"DLY", 30, 128, active=True, formatter=_PLAIN,
              doc="the line's centre time, 0.2..23 ms -- in COMB it is the pitch"),
        Param(b"MODE", 0, 3, active=True, formatter=_STEP,
              labels=("CHOR", "FLNG", "COMB"),
              doc="which line: chorus, flanger or comb (PHSR/TREM/VIB/PAN retired 13 Sep 2026)"),
        Param(b"TONE", 100, 128, active=True, formatter=_PLAIN,
              doc="one-pole damping inside the feedback path; lower = darker each pass"),
        Param(b"SHPE", 0, 4, active=True, formatter=_STEP,
              labels=("TRI", "SIN", "SQR", "SAW"),
              doc="LFO shape: TRI, SIN, SQR (steps the line: a chorus that jumps), SAW (a ramp)"),
        Param(b"WID", 64, 128, active=True, formatter=_PLAIN,
              doc="how far the right channel's LFO lags the left, 0 = mono, 64 = quarter"),
        _BLANK,   # was STGS, the phaser's tap select; the phaser retired 13 Sep 2026
    ),
    # ---- what each MODE renames and re-defaults ---------------------------
    # DLY is the line's centre time and the comb's PITCH; FDBK is the
    # flanger's jet and the comb's ring.
    mode_slot=7,
    mode_views=(
        ModeView(mode=0,                        # CHOR
                 defaults={0: 30, 1: 48, 2: 0, 3: 64, 6: 30, 10: 64}),
        ModeView(mode=1,                        # FLNG
                 defaults={0: 24, 1: 90, 2: 90, 3: 64, 6: 10, 10: 64}),
        # ⚠️ ONLY SLOTS WHOSE MEANING CHANGES ARE RENAMED. Marking a knob
        # dead with "----" in the modes that ignore it read well and cost a
        # cave with 4 bytes to spare -- the doc line says it instead.
        ModeView(mode=2,                        # COMB (was 3 until 13 Sep 2026)
                 names={2: b"RING", 6: b"PTCH"},
                 defaults={0: 8, 1: 20, 2: 110, 3: 64, 6: 20}),
    ),
    dsp=DspSection(
        asm="modules/modulation/modulation.asm",
        priority=14,                  # after the Character station
        bus_role=BusRole.NONE,        # an insert that also WRITES the bus
        ybase=YBase.NEVER,
        r7_latch_slot=0x69,           # ROTLATCH parks this block's offset here
        gate_label=None,              # no housekeeping: a station never elects
    ),
    # The FX1-only allocator buffer: two 1,024-word lines out of the 3,072 an
    # FX1 slot gives. `fx1_only` is the promise that an FX2 instance writes
    # nothing -- the ledger admits it beside a server on that basis, and
    # tools/verify/verify_modulation.py is what proves it.
    claims=Claims(stock_instance_buffer=True, buffer_words=2048, fx1_only=True),
    harness=Harness(layout_char="3", is_server=False, bus_client=True),
)
