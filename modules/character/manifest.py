"""CHARACTER -- everything that dirties or tightens, and a bus sender.

The second BamSep26 station. A per-track INSERT that REPLACES stock LO-FI
(id 0x1c, both menus, and every saved part that chose LO-FI):

  * FOLD -- WarpFold's wavefolder at a held level (the trim, 14 Sep 2026);
    CRUSH, SRR and RING retired the same day for a texture block to come
    ("more of a character than specific effects" -- Sam);
  * SATURATE -- three characters, each a JClones (MIT) clone re-derived
    here (13 Sep 2026): TAPE = TapeHead (a state-variable split at TONE,
    the low and band parts through a cubic smoothstep, the top passed
    clean), TUBE = DaTube (an asymmetric u - u^P curve, the negative half
    driven twice as hard, level-compensated so drive densifies rather than
    turns up), INFL = OInflator (the inflator's signed cubic, DRV is its
    Effect). FUZZ (a hard clip after a tanh) was retired: "very early 2000s
    digi" (Sam). DRV 0 skips the stage, bit-exact;
  * TONE -- a tilt after the saturator in every mode (14 Sep 2026), drawn
    -64..+63: 0 flat and bit-exact, + bright, - dark;
  * COMPRESS -- JClones AC1's console channel law: GLUE (slow) on the
    master BY POSITION, COMP (fast) on every other track, no knob for it
    (14 Sep 2026; TRNS retired 13 Sep 2026);
  * WIDTH -- mid/side width, drawn -64..+63: 0 = untouched, -64 = mono,
    +63 = 2x side. This is what makes the station a master chain on T8;
  * ->DEL / ->VRB -- the station is a BUS CLIENT, exactly as the filter
    station is: knob-gated registration, no housekeeping.

Chain order is fixed: fold -> saturate -> tilt -> compress -> width.
Distortion before dynamics is the order that makes a compressor useful on a
dirty signal rather than a fader for the dirt.

DEFAULTS ARE A BIT-EXACT PASSTHROUGH (DRV 0, FOLD 0, TONE 64, COMP 0, MIX
127, WDTH 64, RET 0), because a part that stored LO-FI
runs this after the flash. ⚠️ A part's STORED bytes are stock LO-FI's --
the stamper (plan A6) writes ours.

The compressor's detector reads a KEY that is the station's own input today;
the ->KEY bus send on the backlog swaps in another track's, which is the
only change needed for sidechain ducking.

THE RETURN IS A KNOB, BY POSITION (13 Sep 2026; "BUS mode" from 3 Sep to
13 Sep). Slot 4, RET, is the bus return level, and it does something on one
track: the master (T8, dispatch position 3 on payload A -- the same pin the
BUS mode used). There the last live stage's wet -- the reverb's if it runs,
else the delay's -- enters at the FRONT of the chain, so glue, saturation,
width and tone treat dry plus wet together, and while RET is up the station
stamps both hosts quiet. Everywhere else RET is inert. Character is one
insert with every mode on every track, T8 included: nothing on the master
can become a bit crusher by turning a select, and nothing off the master
can return the bus. Sam, 13 Sep: "the Elektron way, where everything works
everywhere."

FX1 ONLY (12 Sep 2026): an FX2 instance runs as a dry pass, decided from the
allocator base at init (Claims.fx1_only); the FX2 chooser hides the row.
"""

from remix.schema import (BusRole, Claims, DspSection, Formatter, Harness, Kind,
                          MenuEntry, ModeView, Module, Param, YBase)

_PLAIN = Formatter.PLAIN
_STEP = Formatter.STEPPED
_BIPOL = Formatter.BIPOLAR   # drawn -64..+63 around 64 (14 Sep 2026)

_BLANK = Param(b"", 0)

# post-gain compensation for DRV, 1/sqrt(1 + 15*DRV/128) at DRV 0, 8, .., 128:
# the drive's 1x..16x pre-gain read as a +16 dB fader at the unit's level
# (12 Sep 2026); with this a saturated signal comes out near unity and a
# quiet one gains ~+12 dB at full drive. Read with p:(r5)+, interpolated.
import math as _m
_P = _m.log(10.0) + 1.0
def _q(v): return min(0x7FFFFF, max(0, round(v * (1 << 23))))

# (TUBE's post gain is a per-block division in the source, no table.)
# DaTube's curve: u^P over u in [0, 1], stored as u^P / 2 in 17 pairs (value,
# slope to the next), interpolated in chtube over u/2 (1/32 steps; the
# curve is smooth, and 17 pairs cost 32 words less than 33 -- Character
# has to fit core A beside Modulation and the burn probe). The
# curve itself is T(u) = u - u^P applied to u = 1 - |x|; past |x| = 1 the JSFX
# goes linear, which is the same formula with u^P dropped -- the lookup
# clamps u at 0 and the arithmetic does the rest.
def _tube_up(n=16):
    t = [0.5 * (i / n) ** _P for i in range(n + 1)]
    out = []
    for i in range(n + 1):
        out.append(_q(t[i]))
        out.append(_q(t[i + 1] - t[i]) if i < n else 0)
    return tuple(out)


TUBE_UP = _tube_up()
# TapeHead's drive: d/8 with d = 0.8 * 10^(i/16) (0.8x .. 8x over DRV/128),
# 17 words, interpolated (idx = knob >> 19, frac = the 19 bits under it),
# placed after TUBE_UP's 34 in the P table:
TAPE_D8 = (0x0ccccd, 0x0ec7fd, 0x1111af, 0x13b608, 0x16c311, 0x1a48fe, 0x1e5a84, 0x230d41, 0x287a27, 0x2ebe07, 0x35fa27, 0x3e54f4, 0x47facd, 0x531ef0, 0x5ffc89, 0x6ed7eb, 0x7fffff)


MODULE = Module(
    name="character",
    key="CHARACTER",
    kind=Kind.DSP_EFFECT,
    doc="BamSep26 station: crush, fold/ring, saturation, compressor, width, sends.",
    menu=MenuEntry(
        fx2_id=0x1c,
        replaces="LO-FI",
        donor_desc=0x400d58b8,        # DARK REV: 12 active slots, selects 7/9/11
        abbr=b"CHAR",
        fullname=b"Character",
        build_tag=True,
    ),
    params=(
        # ---- page 1: the performance surface, scene/CC-reachable -----------
        Param(b"DRV", 0, active=True, formatter=_PLAIN,
              doc="saturation drive; 0 skips the stage (bit-exact); TAPE 0.8x..8x"),
        Param(b"FOLD", 0, active=True, formatter=_PLAIN,
              doc="wavefolder drive, 1x..48x into the fold at a held level; 0 = no folding"),
        _BLANK,   # was CRSH (retired 14 Sep 2026); the texture block's slot
        Param(b"COMP", 0, active=True, formatter=_PLAIN,
              doc="compression amount; 0 = no gain reduction at any level"),
        Param(b"RET", 0, active=True, formatter=_PLAIN,
              doc="the bus return level; live on the master (T8) only, inert elsewhere (13 Sep 2026)"),
        Param(b"TONE", 64, active=True, formatter=_BIPOL,
              doc="a tilt after the saturator in every mode: 64 flat, 127 bright, 0 dark (14 Sep 2026)"),
        # ---- page 2: knob / select / knob / select / knob / select ----------
        Param(b"MIX", 127, 128, active=True, formatter=_PLAIN,
              doc="dry/wet across the whole chain; 0 = exact passthrough"),
        Param(b"SAT", 0, 3, active=True, formatter=_STEP,
              labels=("TAPE", "TUBE", "INFL"),
              doc="character: TAPE (TapeHead), TUBE (DaTube, asymmetric), INFL (OInflator). JClones, MIT"),
        _BLANK,   # was RING (retired 14 Sep 2026)
        _BLANK,   # was CMOD: GLUE on the master by position, COMP elsewhere (14 Sep 2026)
        Param(b"WDTH", 64, 128, active=True, formatter=_BIPOL,
              doc="mid/side width, drawn -64..+63: 0 = untouched, -64 = mono, +63 = double the sides"),
        _BLANK,   # was SRR (retired 14 Sep 2026)
    ),
    # No mode views (13 Sep 2026): no knob changes meaning by mode.
    dsp=DspSection(
        asm="modules/character/character.asm",
        ptable=TUBE_UP + TAPE_D8,
        priority=13,                  # after the Spectrum station
        bus_role=BusRole.NONE,        # an insert that also WRITES the bus
        ybase=YBase.NEVER,                # (an FX1 module may own no buffers;
                                          # the return's payload test reads the
                                          # dispatch table instead -- see the source)
        r7_latch_slot=0x69,           # ROTLATCH parks this block's offset here
        gate_label=None,              # no housekeeping: a station never elects
    ),
    # FX1 ONLY (12 Sep 2026): an FX2 instance runs as a dry pass -- the
    # station reads its allocator base at init and returns before touching
    # a frame when it is an FX2 slot. The rig's cycle envelope only closes
    # with the stations on FX1 (tools/harness/pressure.py: four Characters
    # on both slots priced a core at 4,830 against 3,120), the FX2 chooser
    # hides the row, and tools/verify/verify_character.py proves the dry pass.
    claims=Claims(fx1_only=True),
    harness=Harness(layout_char="2", is_server=False, bus_client=True),
)
