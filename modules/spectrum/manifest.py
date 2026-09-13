"""SPECTRUM -- two filters in one insert, and a bus sender.

The first BamSep26 station. A per-track INSERT that REPLACES stock FILTER
(id 0x04, both menus, and every saved part that chose FILTER), built the way
the Digitakt II / Digitone II pair a multimode filter with a base/width
filter -- plus the Sherman-filterbank moves that fit in twelve slots:

  * filter A -- a driven Oberheim SEM zero-delay SVF (Zavalishin's trapezoidal
    form, audiojs/filter's oberheim, MIT; 13 Sep 2026): LP / BP / HP / NOTCH
    from one 2-pole core, no cutoff ceiling, stable at any RES, the cutoff
    ramped per sample across the block; and a VOWL mode that is a real
    three-formant bank (constant-peak-gain resonators, audiojs formant /
    resonator) morphed across A E I O U by FREQ, RES narrowing the bands --
    it no longer borrows the SVF, so ROUT keeps its meaning in VOWL; and a
    LADR mode (13 Sep 2026): the linear zero-delay Moog transistor ladder
    (audiojs/filter moogLadder, MIT), 24 dB/oct, resonance to the edge of
    self-oscillation at RES 127 and bounded there;
  * filter B -- a base/width pair: two cascaded one-poles of HP at BASE and
    two of LP at WDTH (12 dB/oct each side);
  * routing -- SER (A into B), PAR (A + B), RING (A x B), FM (B's output
    modulates A's cutoff at audio rate, one sample late);
  * modulation -- one bipolar DPTH onto A's cutoff, from an envelope follower
    (block-peak, instant attack, RATE = release), an LFO (RATE = speed), or
    both;
  * ->DEL / ->VRB -- the station is a BUS CLIENT: the processed signal is
    sent onto both buses, page 1, scene-lockable. It registers only when a
    send is non-zero (the N/(N+1) dilution trap) and NEVER HOUSEKEEPS: the
    election is the FX2 participants' business, so an FX1 station on track 5
    cannot double-flip the rotation with its own FX2.

DEFAULTS ARE A BIT-EXACT PASSTHROUGH (FREQ 127, RES 0, BASE 0, WDTH 127,
DPTH 64, LP, SER, sends 0; DRV retired 13 Sep 2026 -- Character owns drive): the engine detects that block and copies
nothing, because after the flash every part that ever chose FILTER runs
this on FX1. ⚠️ A part's STORED bytes are stock FILTER's, not these defaults
(DEC=64 lands on ->VRB): the project stamper writes ours (plan A6).

Every mpy is `mpy x0,y1`, the audited-signed form; every clip is the store
limiter. Cycles: the whole loop is straight-line and priced by `make cycles`.
"""

from remix.schema import (BusRole, Claims, DspSection, Formatter, Harness, Kind,
                          MenuEntry, Module, Param, YBase)

_PLAIN = Formatter.PLAIN
_STEP = Formatter.STEPPED

_BLANK = Param(b"", 0)

# The SEM core's g/2 = tan(pi*fc/fs)/2 at FREQ 0, 4, .., 128 for fc = 24 Hz *
# 625^(FREQ/128): exponential, 9.3 octaves to 15 kHz, an equal step per
# detent (13 Sep 2026; the Chamberlin table it replaced held 2*sin(pi*fc/fs)
# to 7.2 kHz, that topology's stable ceiling). Halved so g stays a
# fraction: tan at 15 kHz is 1.82.
G2_TABLE = (
    0x001c03, 0x002241, 0x0029e3, 0x003339, 0x003ea3, 0x004c98,
    0x005daa, 0x00728a, 0x008c10, 0x00ab47, 0x00d173, 0x010021,
    0x013938, 0x017f0b, 0x01d472, 0x023cea, 0x02bcb9, 0x035923,
    0x04189e, 0x05032a, 0x0622b3, 0x0783a2, 0x0935a9, 0x0b4ce9,
    0x0de3ca, 0x111dfe, 0x152dca, 0x1a5de8, 0x21258f, 0x2a54ef,
    0x3785f2, 0x4c7450, 0x748895,
)

# VOWL: cos(2*pi*F/fs) for five vowels x three formants, Peterson & Barney
# (1952) male means as the classic formant tables carry them --
# a 730/1090/2440, e 530/1840/2480, i 270/2290/3010, o 570/840/2410,
# u 300/870/2240 Hz; bandwidths 90/110/170 Hz are constants in the asm.
COS_TABLE = (
    0x7f4eed, 0x7e75a6, 0x7857c9, 0x7fa29f, 0x7ba06f,
    0x7817aa, 0x7fe7c2, 0x793f4f, 0x7468a6, 0x7f9401,
    0x7f159c, 0x788738, 0x7fe212, 0x7f0497, 0x798957,
)

MODULE = Module(
    name="spectrum",
    key="SPECTRUM",
    kind=Kind.DSP_EFFECT,
    doc="BamSep26 station: dual filter (SVF + base/width), LFO/env, SER/PAR/RING/FM, sends.",
    menu=MenuEntry(
        fx2_id=0x04,
        replaces="FILTER",            # stock FILTER's id: both menus, every part
        donor_desc=0x400d58b8,        # DARK REV: 12 active slots, selects on 7/9/11
        abbr=b"SPEC",
        fullname=b"Spectrum",
        build_tag=True,
    ),
    params=(
        # ---- page 1: the performance surface, scene/CC-reachable -----------
        Param(b"FREQ", 127, active=True, formatter=_PLAIN,
              doc="filter A cutoff, 24 Hz..15 kHz exponential taper; in VOWL the vowel A-E-I-O-U"),
        Param(b"RES", 0, active=True, formatter=_PLAIN,
              doc="filter A resonance, up to Q~33 (self-oscillates, bounded); in VOWL the formants' bandwidth"),
        Param(b"BASE", 0, active=True, formatter=_PLAIN,
              doc="filter B high-pass corner (12 dB/oct); 0 = open"),
        Param(b"WDTH", 127, active=True, formatter=_PLAIN,
              doc="filter B low-pass corner above BASE (12 dB/oct); 127 = open"),
        _BLANK,   # -DEL: the stations lost their sends in the one-aux rig (7 Sep 2026)
        _BLANK,   # -VRB: the stations lost their sends in the one-aux rig (7 Sep 2026)
        # ---- page 2: knob / select / knob / select / knob / select ----------
        _BLANK,   # DRV retired 13 Sep 2026 (Sam: "we have DRVs everywhere" -- Character owns drive)
        Param(b"MODE", 0, 6, active=True, formatter=_STEP,
              labels=("LP", "BP", "HP", "NTCH", "VOWL", "LADR"),
              doc="filter A response; VOWL = formant bank morphed by FREQ; LADR = the Moog ladder, 24 dB/oct"),
        Param(b"DPTH", 64, 128, active=True, formatter=_PLAIN,
              doc="modulation depth onto A's cutoff, bipolar around 64 = none"),
        Param(b"ROUT", 0, 4, active=True, formatter=_STEP,
              labels=("SER", "PAR", "RING", "FM"),
              doc="SER A into B; PAR A+B; RING A*B; FM B's output modulates A's cutoff"),
        Param(b"RATE", 64, 128, active=True, formatter=_PLAIN,
              doc="LFO speed ~0.08..9 Hz, and the envelope release (0 slow .. 127 fast)"),
        Param(b"SRC", 0, 3, active=True, formatter=_STEP,
              labels=("ENV", "LFO", "BOTH"),
              doc="what DPTH applies: the envelope follower, the LFO, or half of each"),
    ),
    dsp=DspSection(
        asm="modules/spectrum/spectrum.asm",
        # FREQ's taper: 33 SVF f coefficients (Q23, 2*sin(pi*fc/fs)) at FREQ
        # 0, 4, .., 128 for fc = 24 Hz * 300^(FREQ/128) -- exponential, 8.2
        # octaves, an equal step per detent -- read with p:(r5)+ and
        # interpolated linearly per block (12 Sep 2026). The squared law it
        # replaced put half the dial above 2 kHz (station_laws.py).
        ptable=G2_TABLE + COS_TABLE,
        priority=12,                  # after every existing module
        bus_role=BusRole.NONE,        # an insert that also WRITES the bus
        ybase=YBase.NEVER,
        gate_label=None,              # no housekeeping, so no XBUS gate
    ),
    # NOT a bus client since 12 Sep 2026: the sends went with the one-aux rig
    # (7 Sep) and the bus bookkeeping went with them.
    # FX1 ONLY (12 Sep 2026): an FX2 instance runs as a dry pass -- the
    # station reads its allocator base at init and returns before touching
    # a frame when it is an FX2 slot. The rig's cycle envelope only closes
    # with the stations on FX1 (tools/harness/pressure.py: four Characters
    # on both slots priced a core at 4,830 against 3,120), the FX2 chooser
    # hides the row, and tools/verify/verify_spectrum.py proves the dry pass.
    claims=Claims(fx1_only=True),
    harness=Harness(layout_char="1", is_server=False, bus_client=False),
)
