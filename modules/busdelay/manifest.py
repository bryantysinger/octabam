"""BusDelay -- a multi-mode delay: CLEAN, GRAIN (pitched), REVERSE.

Two 32K lines on the shipping core (741 ms of TIME): LineL the shared half,
LineR core 1's private FX2 buffer region Y:0x4000-0xBFFF, which the reverb's
tank owns on core 0 and nothing writes on core 1 (port, 15 Sep 2026). The
DEV hatch keeps two 16K lines (tools/remix/geom.py).

Clones SPRING REV's descriptor. A cloned descriptor inherits the donor's
display formatter, which overrides the value count, so every slot below
states its renderer. TIME's formatter is the tempo-sync cave, registered
over slot 0 by that module.
"""

from remix.schema import (ModeView, BusRole, Claims, YBase, DspSection, Formatter, Harness, Kind,
                          MenuEntry, Module, Param)

_PLAIN = Formatter.PLAIN
_STEP = Formatter.STEPPED

# ---- the P table ----------------------------------------------------------
# SIZE rows, eight words each: REVERSE's [S, 2^23/S, 32704 - 2S] on the left
# and GRAIN's [G-1, G/4, 2^(23-k), 2^(32-k)] on the right, one pad. Rows 0..3
# are the four select positions in the engine's index order; row 4 is the
# garbage row: the engine clamps any index of 4 and up (a stale part byte
# holds 0..127) onto it, row 0's REVERSE half with row 3's GRAIN half. Read
# by delay_server.asm's table block; the build parks it in the stock curve
# bank X:0x4840 beside SPECTRUM's and CHARACTER's tables.
SIZE_ROWS = (
    # index 1 (93 ms) is the panel default; 46 ms is comb territory on
    # sustained sources
    (2048,  4096, 28608, 0x7ff,  0x200, 0x1000, 0x200000, 0),   # 0: 46 ms
    (4096,  2048, 24512, 0xfff,  0x400, 0x800,  0x100000, 0),   # 1: 93 ms (default)
    (1024,  8192, 30656, 0x3ff,  0x100, 0x2000, 0x400000, 0),   # 2: 23 ms
    # 3: XTRM -- REVERSE S = 16384 (371 ms), cap 0: the lag floor is TIME-free
    # at this size, 2S - 2 = 32,766 is the mono ring's oldest valid sample.
    # GRAIN: 8192-sample (186 ms) grains.
    (16384, 512,  0,     0x1fff, 0x800, 0x400,  0x80000,  0),
    (2048,  4096, 28608, 0x1fff, 0x800, 0x400,  0x80000,  0),   # 4+: garbage index
)
# The sticky snap's twelve tempo divisions, M << 11 for M in 2, 3, 4, 6, 8,
# 9, 12, 16, 18, 24, 32, 36 (1/32T .. 1/4.; 1/2 = 48 never fits the 741 ms
# line below 162 BPM, 1/4. fits from 122), smallest first -- last match wins
# in the engine's loop. At offset 40.
SNAP_DIVS = (0x1000, 0x1800, 0x2000, 0x3000, 0x4000,
             0x4800, 0x6000, 0x8000, 0x9000, 0xc000, 0x10000, 0x12000)
# The bus auto-gain's 1/sqrt(N), Q23, indexed by the client count masked to
# 0..7 -- so [0] is 1/sqrt(8), where eight writers wrap to (and a count of 0
# lands harmlessly: the accumulator is zero then). 1/sqrt(N) because
# uncorrelated senders sum as sqrt(N). At offset 52.
RECIP = (0x2d413c, 0x7fffff, 0x5a8279, 0x49e69d,
         0x400000, 0x393e4b, 0x34417a, 0x306123)
PTABLE = tuple(w for row in SIZE_ROWS for w in row) + SNAP_DIVS + RECIP

MODULE = Module(
    name="busdelay",
    key="DELAY SERVER",
    kind=Kind.DSP_EFFECT,
    doc="Multi-mode delay: CLEAN / pitched GRAIN cloud / REVERSE, tape wow, freeze.",
    menu=MenuEntry(
        fx2_id=0x06,
        donor_desc=0x400d5726,        # SPRING REV
        abbr=b"BDLY",
        fullname=b"BusDelay",
        build_tag=False,              # the tag is added by the XBUS/DEV arms
    ),
    params=(
        # ---- page 1 -------------------------------------------------------
        # SEND at slot 0 on every track, hosts included: this host's own dry
        # send into the aux (headroomed, summed, counted only while nonzero).
        Param(b"SEND", 0, active=True, formatter=_PLAIN,
              doc="this track's send into the one aux bus (delay, then reverb, back on T8)"),
        Param(b"TIME", 20, active=True, formatter=_PLAIN,
              doc="delay time, 1.5 .. 739 ms -- a free dial that sticky-snaps to tempo divisions"),
        Param(b"FDBK", 60, active=True, formatter=_PLAIN,
              doc="feedback -- how much each repeat regenerates"),
        Param(b"TONE", 100, active=True, formatter=_PLAIN,
              doc="tone of the repeats -- lower = darker every pass"),
        # PING 0 = centred. Measured at FDBK 60: 0 mono (L/R correlation
        # 1.000), 32 / 64 near-mono (0.998 / 0.965), the alternation is in
        # 96..127 (0.73 / 0.01); 127 leans +4.4 dB left (L gets repeats 1, 3,
        # 5: L/R = 1/feedback).
        Param(b"PING", 0, active=True, formatter=_PLAIN,
              doc="stereo ping-pong spread; 0 = centred, the alternation is in the top quarter"),
        # WET: the repeats' level on top of the send. out = in + wet*WET goes
        # on to the reverb and to the return: the send passes through the
        # pedal at unity, WET adds the repeats (a crossfade until 15 Sep
        # 2026). The chain itself is hardwired.
        Param(b"WET", 127, active=True, formatter=_PLAIN,
              doc="the repeats' level; the send passes through at unity"),
        # ---- page 2 -------------------------------------------------------
        # MODE on slot 6: an even slot is the one the panel's page-2 knob
        # editor writes (docs/firmware/MAINMENU.md 9c-ii). The DSP reads $c's
        # KNOB field for it.
        Param(b"MODE", 0, 3, active=True, formatter=_STEP,
              labels=("CLEAN", "GRAIN", "REVRS"),
              doc="engine select: CLEAN, GRAIN (pitched cloud, v5), REVERSE"),
        # MDEP on slot 7: delivered in $c's companion field (bits 8-15), as
        # stock FILTER's DIST knob is on slot 11. Default 0: an aux delay
        # sits still.
        Param(b"MDEP", 0, 128, active=True, formatter=_PLAIN,
              doc="tape mod (wow) depth; 0 = none - GRAIN: scatter, how far apart the grains read"),
        # MRAT 64 = exactly 1x; the DPTH=0 bypass gate depends on it.
        Param(b"MRAT", 64, 128, active=True, formatter=_PLAIN,
              doc="tape mod (wow) rate, 64 = 1x - GRAIN: density, full dial, level-flat (R61)"),
        # SIZE: GRAIN's grain length and REVERSE's segment, one select.
        Param(b"SIZE", 1, 4, active=True, formatter=_STEP,
              labels=("46MS", "93MS", "23MS", "XTRM"),
              doc="segment/grain size 46/93/23 ms; XTRM = 186 ms grains, 371 ms REVERSE segments"),
        # PTCH on page-2 slot 10: the DSP reads $e's KNOB field. GRAIN's
        # pitch; idle in other modes.
        Param(b"PTCH", 64, 128, active=True, formatter=_PLAIN,
              doc="GRAIN pitch, +-2 oct, 64 = unison (a held MIDI note overrides); idle in other modes"),
        Param(b"FRZE", 0, 2, active=True, formatter=_STEP,
              labels=("RUN", "HOLD"),
              doc="freeze the line as a loop -- loop length = TIME"),
    ),
    # ---- what each MODE renames and re-defaults ---------------------------
    # MDEP and MRAT are the tape modulation depth and rate in CLEAN and
    # REVERSE, the grain scatter and density in GRAIN.
    mode_slot=6,
    mode_views=(
        # slots: 1 TIME, 2 FDBK, 3 TONE, 4 PING, 5 MIX, 10 PTCH; SEND at 0 is
        # never re-defaulted by a mode. TIME is 64 + knob*256 samples since
        # the 32K lines (15 Sep 2026): 20 = 5,184 samples, 18 = 4,672 -- the
        # same times the views held at 40 / 36 under the old *128 law.
        ModeView(mode=0,                        # CLEAN: centred, no wow
                 defaults={1: 20, 2: 60, 3: 100, 4: 0, 5: 127,
                           7: 0, 8: 64, 10: 64}),
        ModeView(mode=1,                        # GRAIN
                 names={7: b"SCAT", 8: b"DENS"},   # PTCH is PTCH in every mode
                 # Sam's recipe on the unit (15 Sep 2026): octave up, ping-pong
                 defaults={1: 18, 2: 40, 3: 100, 4: 127, 5: 127,
                           7: 40, 8: 127, 9: 1, 10: 96}),
        ModeView(mode=2,                        # REVERSE: centred, no wow, 371 ms
                 defaults={1: 20, 2: 60, 3: 100, 4: 0, 5: 127,   # segments (SIZE 3 = XTRM)
                           7: 0, 8: 64, 9: 3, 10: 64}),
    ),
    dsp=DspSection(
        asm="modules/busdelay/delay_server.asm",
        priority=2,                       # last: the region's trailing free
                                          # words are its growth room
        payloads=frozenset({"B"}),        # the core serving tracks 1-4
        bus_role=BusRole.SERVER,
        ybase=YBase.ALWAYS,               # its 32K of lines live at the base
        # DEV puts the delay in payload A; based at 0x30000 its lines would
        # sweep the reverb's buffers, the bus scratch and both role locks
        # every 16,384 samples, so it keeps its shipping base.
        dev_pin_ybase=0x38000,
        r7_latch_slot=0x86,               # payload B tracks its own rotation
        gate_label="bus_notfirst",
        override_markers=("; DMODE_OVERRIDE", "; DINT_OVERRIDE",
                          "; DFRZ_OVERRIDE", "; DNOTE_OVERRIDE"),
        ptable=PTABLE,
    ),
    # The source names 0901h-0903h as this module's RATE/DRV state block; the
    # scan sees 0901 and 0902. 0903 is reserved because whether it is live
    # is not established.
    # LineR is the core's private FX2 buffer region: the ledger refuses a
    # second owner on the same payload (BusVerb's tank is payload A's).
    claims=Claims(reserved_private_y=(0x0903,), owns_fx2_buffers=True),
    harness=Harness(layout_char="D", is_server=True),
)
