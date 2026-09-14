"""BusVerb -- an eight-line FDN reverb with shimmer, gating and mode select.

Hosted on payload A (core 0), which serves TRACKS 5-8 -- measured 10 Aug 2026
and inverted from what every doc assumed before then. Test it on track 5.
Any track can send into it over the bus.

Clones DARK REV's descriptor. Slot 0 is written with the name the donor
already carries (TIME), so the write is a no-op in bytes but the label is
stated here rather than inherited silently -- the harness reads these names,
and a name that exists only in a donor is a name no tool can see. (Slots 3
and 4 were the donor's HP/LP until v8; they are TONE and -DEL now.)
"""

from remix.schema import (BusRole, Claims, YBase, DspSection, Formatter,
                          Harness, Kind, MenuEntry, Module, Param)

_PLAIN = Formatter.PLAIN
_STEP = Formatter.STEPPED


# ---- the module's P table (14 Sep 2026) -------------------------------------
# Read by reverb_server.asm through ONE table literal (build_bus.py rewrites
# it to the table's address and parks the words in the stock curve bank,
# X:0x4840, beside the LFO table -- see modules/spectrum for the mechanism).
# Two things live here, both formerly rebuilt or stored by straight-line code
# every block:
#
# 1. THE RECIPROCAL TABLE, first: 1/sqrt(N) for N = 8 (index 0 -- a count of 8
#    wraps to it), 1..7 -- the bus auto-gain, indexed by the client count.
_RECIP = (0x2d413c, 0x7fffff, 0x5a8279, 0x49e69d, 0x400000, 0x393e4b,
          0x34417a, 0x306123)
RECIP_WORDS = len(_RECIP)             # 8 -- `move #8,n5` in the engine
#
# 2. THE MODE ROWS, after them. Each MODE is seventeen (r7 slot, value) pairs
#    the engine copies into its r7 block after warm-up, at a 64-word stride
#    (the index arrives MSB-aligned, $010000 per step, and `asr #$a` turns it
#    into the row offset for free). The voicing notes that sat beside each
#    constant in the md_* blocks are condensed here; the full history is in
#    git (reverb_server.asm before 14 Sep 2026).
_MODE_SLOTS = (
    0x1e,   # k_mode: the TIME law's mode constant (13 Sep 2026; was the decay scale)
    0x20,   # wet gain/2 (R18 full-wet; BIG carries its own -3 dB trim)
    0x74, 0x75, 0x76, 0x77,   # lines 0-3 taps as fractions of the 4096-word line
    0x6f,   # tap scale: SIZE moves within a character rather than replacing it
    0x3f,   # diffusion offset, added to DIFF's span (Round 13)
    0x72,   # damping scale: multiplies the TONE-derived coefficient; smaller = darker
    0x73,   # mod depth scale: only ever scales DOWN, BIG sits at unity
    0x7a,   # wet high-cut coefficient (Round 11)
    0x6c,   # lines 4-7 tap scale, the interleave (NOT $0c: that is the bus gain)
    0x7e, 0x7f, 0x80, 0x81,   # input diffuser taps 641/1051/1511/1949 as 2048-tap
    0x2f,   # MODE's LFO RATE scale (1.0 for all three)
)
_MODE_ROWS = {
    # ROOM: k_mode 0.5; taps 3958/3386/2894/2474; tap scale 0.60 (Round 13,
    # was 0.45); damping 0.953 -- the loop barely damps, tone lives in the wet
    # high-cut; high-cut 0.523 (VV room is "darker tone"); interleave 0.71875.
    "ROOM":  (0x400000, 0x7e8000, 0x3DD800, 0x34E800, 0x2D3800, 0x26A800,
              0x4CCCCD, 0x100000, 0x7A0000, 0x7fffff, 0x430000, 0x5c0000),
    # PLATE: k_mode 0.4 (set EMPIRICALLY against VV plate's decay rate at
    # TIME~32); taps 3528/3283/3056/2845; tap scale 0.5625; damping 0.78 (a
    # brighten to 0.879 was built and reverted 18 Aug 2026 -- the hardware
    # tilt was the test part's stored LP); high-cut 0.68, the bright one;
    # interleave 0.765625.
    "PLATE": (0x333333, 0x7e8000, 0x372000, 0x334C00, 0x2FC000, 0x2C7400,
              0x480000, 0x100000, 0x640000, 0x7fffff, 0x570000, 0x620000),
    # BIG: k_mode 0.25; wet gain/2 -3 dB vs the others (18 Aug 2026, the
    # clean-part correction of an old-part -6); taps 4050/3403/2860/2403;
    # tap scale 1.0, the largest space; diffusion offset ROOM's old level;
    # damping 0.90 (R18) -- chosen on retention over equal TIME, c^(1/tapscale),
    # since BIG's longer lines damp less often; mod depth 0.60 (Round 13);
    # high-cut 0.60 ~6.4 kHz, still below PLATE by design; interleave 0.789.
    "BIG":   (0x200000, 0x5a0000, 0x3F4800, 0x352C00, 0x2CB000, 0x258C00,
              0x7fffff, 0x0c0000, 0x733333, 0x4CCCCD, 0x4CCCCD, 0x650000),
}
_MODE_COMMON = (1407, 997, 537, 99, 0x7fffff)
_MODE_STRIDE = 64


def _table():
    words = list(_RECIP)
    for name in ("ROOM", "PLATE", "BIG"):        # MODE index 0, 1, 2
        row = []
        for slot, value in zip(_MODE_SLOTS, _MODE_ROWS[name] + _MODE_COMMON,
                               strict=True):
            row += [slot, value]
        assert len(row) == 2 * 17 <= _MODE_STRIDE
        words += row
        if name != "BIG":                        # the last row needs no padding
            words += [0] * (_MODE_STRIDE - len(row))
    assert len(words) == RECIP_WORDS + 2 * _MODE_STRIDE + 2 * 17   # 170
    return tuple(words)

MODULE = Module(
    name="busverb",
    key="REVERB SERVER",
    kind=Kind.DSP_EFFECT,
    doc="Eight-line FDN reverb: ROOM/PLATE/BIG, shimmer, gate, mid/side width.",
    menu=MenuEntry(
        fx2_id=0x07,
        donor_desc=0x400d58b8,        # DARK REV
        abbr=b"BVRB",
        fullname=b"BusVerb",
        build_tag=True,
    ),
    params=(
        # ---- page 1 -------------------------------------------------------
        # THE ONE-AUX RE-SLOT (7 Sep 2026): AUX at slot 0 on EVERY track,
        # hosts included -- it is the host's own dry send into the one aux
        # bus (the v8 ->DEL machinery). 0 is load-bearing: a non-zero default
        # would register every idle host as a client and dilute the real
        # senders (the -6.02 dB phantom-client defect).
        Param(b"AUX", 0, active=True, formatter=_PLAIN,
              doc="this track's send into the one aux bus (delay, then reverb, back on T8)"),
        Param(b"TIME", 64, active=True, formatter=_PLAIN,
              doc="decay time -- how long the tail rings"),
        Param(b"MOD", 30, active=True, formatter=_PLAIN,
              doc="tank modulation depth -- 0 static, high = chorused tail; speed is RATE"),
        Param(b"SIZE", 100, active=True, formatter=_PLAIN,
              doc="room size -- scales the eight tank lines (taps up to ~89 ms)"),
        # TONE (v8, 5 Sep 2026) is the old HP + LP pair on ONE knob, so that
        # slot 4 can carry the host's ->DEL send: 0..64 closes the high cut
        # (dark), 64..127 opens the low cut inside the loop (thin). 64 IS the
        # old defaults (HP 0 / LP 127), bit-identical.
        Param(b"TONE", 64, active=True, formatter=_PLAIN,
              doc="tail tone: below 64 darkens (high cut), above 64 thins (low cut); 64 = flat"),
        # MIX (one-aux rig, 7 Sep 2026; IN until then): the STAGE's crossfade.
        # The reverb is chain stage 2: out = in*(1-MIX) + wet*MIX, where `in`
        # is the delay's output while the delay is live, else the aux. 127
        # is the old wet-only return; lower lets the delay's repeats (or the
        # dry aux) survive the tail. The host prints wet*MIX under its dry.
        Param(b"MIX", 127, active=True, formatter=_PLAIN,
              doc="stage dry/wet: 0 passes the chain input through, 127 = wet only"),
        # ---- page 2 ---------------------------------------------------------
        # MODE on slot 6 (v7, 4 Sep 2026; was slot 7). An even slot is the
        # proven slot the panel's page-2 knob editor writes, so a main-menu
        # screen can set
        # MODE through the firmware's own routine; slot 7's select path needs
        # UI state nobody has mapped (docs/firmware/MAINMENU.md 9c-ii). The DSP reads
        # it from $c's KNOB field now (bits 16-23). A part saved before the
        # swap loads its old SHMR byte as MODE and its old MODE as SHMR --
        # ROOM and a whisper of shimmer at worst; re-select the effect.
        # PLATE by default (12 Sep 2026; was BIG). Measured on the loop at
        # the unit's level the three wet levels sit within 2 dB now (ROOM
        # -16.9, PLATE -19.1, BIG -19.0 dBFS at defaults, AUX 100) -- the
        # "7-9 dB apart" note predated the re-laws -- so the default is the
        # conventional shared plate rather than the biggest space.
        Param(b"MODE", 1, 3, active=True, formatter=_STEP,
              labels=("ROOM", "PLATE", "BIG"),
              doc="voicing: ROOM / PLATE / BIG; BIG clips first"),
        # SHMR defaults OFF. The slot used to be SPEED (the LFO rate) with a
        # default of 48; when it became the shimmer amount the default was
        # never revisited, so a fresh part booted with the shimmer half up.
        # SHMR=0 is bit-identical to the pre-shimmer engine. On slot 7 it is
        # delivered in $c's companion field (bits 8-15), like stock FILTER's
        # DIST knob on slot 11.
        Param(b"SHMR", 0, 128, active=True, formatter=_PLAIN,
              doc="shimmer -- pitch-shifted regeneration in the tail; 0 = off"),
        # DIFF 80 by default (12 Sep 2026; was 64): R59's VintageVerb match
        # point bracketed at ~80-90, never applied.
        Param(b"DIFF", 80, 128, active=True, formatter=_PLAIN,
              doc="diffusion -- low = discrete repeats, high = smooth wash"),
        # SHFT selects the shimmer interval +12/+19/+7/-12 (v6; was WIDTH,
        # which is retired and pinned wide). An old project's stored WIDTH=3
        # loads here as -12, which is benign at SHMR's 0 default.
        Param(b"SHFT", 0, 4, active=True, formatter=_STEP,
              labels=("+12", "+19", "+7", "-12"),
              doc="shimmer interval in semitones -- heard once SHMR is up"),
        Param(b"GATE", 0, 128, active=True, formatter=_PLAIN,
              doc="gated-reverb hold -- higher holds longer; the useful range is low (8-20)"),
        # MOD speed select, 0.5/1/2/4x. Index 1 is 1x; the panel shows it
        # 1-based, so it reads as "2".
        Param(b"RATE", 1, 4, active=True, formatter=_STEP,
              labels=("0.5x", "1x", "2x", "4x"),
              doc="MOD speed multiplier; the panel shows it 1-based"),
    ),
    dsp=DspSection(
        asm="modules/busverb/reverb_server.asm",
        priority=1,                       # after SEND, before the delay
        # Payload A -> the core serving TRACKS 5-8 (the docstring's measured
        # inversion). The build's SPEC table still hardcodes this pairing;
        # here it is stated so the remixer can derive the track range.
        payloads=frozenset({"A"}),
        bus_role=BusRole.SERVER,
        # Six occurrences (were eight until the reciprocal table moved into
        # the ptable, 14 Sep 2026): the relocated tank buffers at
        # 0x30000/0x34000. The per-payload rewrite of this literal is
        # load-bearing, not a formality -- but only once the bus lives in
        # the shared window.
        ybase=YBase.XBUS,
        r7_latch_slot=None,               # payload A is in lockstep with the
                                          # rotation flip and latches nothing
        gate_label="bus_notfirst",
        override_markers=("; MODE_OVERRIDE",),
        ptable=_table(),                  # the reciprocals + MODE rows, above
    ),
    # The eight tank lines are hardcoded into Y:0x4000-0xBFFF, the per-CORE
    # FX2 instance buffer region -- so nothing else that owns memory there
    # can be hosted on the same core (the ledger refuses the pair).
    claims=Claims(owns_fx2_buffers=True),
    harness=Harness(layout_char="R", is_server=True),
)
