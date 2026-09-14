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
LDP 0, MODE 0 = LADR, sends 0; DRV retired 13 Sep 2026 -- Character owns drive): the engine detects that block and copies
nothing, because after the flash every part that ever chose FILTER runs
this on FX1. ⚠️ A part's STORED bytes are stock FILTER's, not these defaults
(DEC=64 lands on ->VRB): the project stamper writes ours (plan A6).

Every mpy is `mpy x0,y1`, the audited-signed form; every clip is the store
limiter. Cycles: the whole loop is straight-line and priced by `make cycles`.
"""

from remix.schema import (ModeView, BusRole, Claims, DspSection, Formatter, Harness, Kind,
                          MenuEntry, Module, Param, YBase)

_PLAIN = Formatter.PLAIN
_STEP = Formatter.STEPPED
_BIPOL = Formatter.BIPOLAR   # drawn -64..+63 around 64 (14 Sep 2026)

_BLANK = Param(b"", 0)

# The SEM core's g/2 = tan(pi*fc/fs)/2 at FREQ 0, 4, .., 128 for fc = 60 Hz *
# 250^(FREQ/128): exponential, 8 octaves to 15 kHz, an equal step per detent
# (the floor was 24 Hz until 14 Sep 2026 -- Sam: "freq goes all the way to
# silent"; 13 Sep 2026; the Chamberlin table it replaced held 2*sin(pi*fc/fs)
# to 7.2 kHz, that topology's stable ceiling). Halved so g stays a
# fraction: tan at 15 kHz is 1.82.
G2_TABLE = (
    0x004608, 0x005338, 0x0062e4, 0x007584, 0x008ba6, 0x00a5f3,
    0x00c534, 0x00ea59, 0x01167d, 0x014af3, 0x01894c, 0x01d367,
    0x022b7d, 0x029435, 0x0310b7, 0x03a4cb, 0x0454f5, 0x0526a1,
    0x06205b, 0x074a11, 0x08ad72, 0x0a5676, 0x0c541f, 0x0eb998,
    0x11a007, 0x15297c, 0x198619, 0x1efd7f, 0x260151, 0x2f5508,
    0x3c6e04, 0x508579, 0x748894,
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

# VOWL's per-formant constants, after the COS table: for each formant k the
# pair (e_k, R_k) with R_k = exp(-pi*bw_k/fs) for bw = 90 / 110 / 170 Hz and
# e_k = 0.9*(1 - R_k), the RES narrowing (R' = R_k + e_k*RES). Read with
# p:(r2)+ by the one per-block formant loop (14 Sep 2026: they were three
# copies of the block, each with its own two immediates).
VOWL_ER = (
    0x00bc7a, 0x7f2e95,
    0x00e632, 0x7f003a,
    0x0162ff, 0x7e758f,
)

MODULE = Module(
    name="spectrum",
    key="SPECTRUM",
    kind=Kind.DSP_EFFECT,
    doc="BamSep26 station: a filter pedal -- SEM LP/BP/HP, Airwindows Capacitor2, formants, the Moog ladder; ENV and LFO onto the cutoff; width.",
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
              doc="the cutoff, 60 Hz..15 kHz exponential; in VOWL the vowel A-E-I-O-U; ENV and LFO move it"),
        Param(b"RES", 0, active=True, formatter=_PLAIN,
              doc="the flavour: resonance in LP/BP/LADR, sharpness in VOWL, the dielectric colour in ISO"),
        Param(b"ENV", 64, 128, active=True, formatter=_BIPOL,
              doc="the envelope follower onto the cutoff, drawn -64..+63; 0 = none"),
        Param(b"LDP", 0, active=True, formatter=_PLAIN,
              doc="LFO depth onto the cutoff, 0 = none (a negative depth would only flip the phase)"),
        Param(b"LSP", 64, 128, active=True, formatter=_PLAIN,
              doc="LFO speed ~0.08..9 Hz, and the envelope release (0 slow .. 127 fast)"),
        Param(b"WDTH", 64, 128, active=True, formatter=_BIPOL,
              doc="stereo width of the output, drawn -64..+63: 0 untouched, -64 mono, +63 double sides"),
        # ---- page 2: knob / select / knob / select / knob / select ----------
        Param(b"TAME", 50, active=True, formatter=_PLAIN,   # 50: Sam, image 20
              doc="the filter's own saturation (the SEM/Moog tanh), every mode: 0 off; up tames resonance"),
        Param(b"MODE", 0, 5, active=True, formatter=_STEP,
              labels=("LADR", "LP", "BP", "ISO", "VOWL"),
              doc="LADR the Moog (first: the best one); LP/BP the SEM; ISO an isolator (Capacitor2); VOWL"),
        _BLANK,   # was DPTH (14 Sep 2026: ENV and LFO on page 1)
        _BLANK,   # was ROUT (SER/PAR/RING/FM: filter B retired 14 Sep 2026)
        _BLANK,   # was RATE (14 Sep 2026: LSP beside LDP on page 1)
        _BLANK,   # was SRC (14 Sep 2026: both depths have their own knob)
    ),
    # Option B (14 Sep 2026): FREQ is always where, RES always the flavour;
    # a mode labels RES for what it is there. ISO's defaults
    # (a stamp lands them; the live re-default on MODE is stage B's open
    # ColdFire half). Five positions: the tick widget draws five (14 Sep 2026).
    mode_slot=7,
    mode_views=(ModeView(mode=3, names={0: b"LOW", 1: b"COLR"}, defaults={0: 127, 1: 64}),
                ModeView(mode=4, names={1: b"SHRP"})),
    dsp=DspSection(
        asm="modules/spectrum/spectrum.asm",
        # FREQ's taper: 33 SVF f coefficients (Q23, 2*sin(pi*fc/fs)) at FREQ
        # 0, 4, .., 128 for fc = 24 Hz * 300^(FREQ/128) -- exponential, 8.2
        # octaves, an equal step per detent -- read with p:(r5)+ and
        # interpolated linearly per block (12 Sep 2026). The squared law it
        # replaced put half the dial above 2 kHz (station_laws.py).
        ptable=G2_TABLE + COS_TABLE + VOWL_ER,
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
