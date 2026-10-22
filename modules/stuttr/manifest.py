"""STUTTR -- chance-engaged grain repeater.

Mostly dry; RATE ticks roll CHNC to grab a SIZE grain and HOLD-loop it.
MODE sets playback rate (FWD / HALF / QUART / RND); REV is per-repeat
reverse probability. MIX 0 is bit-exact dry.
"""

from remix.schema import (BusRole, Category, Claims, DspSection, Formatter, Gate,
                          Harness, Kind, MenuEntry, Module, Param, Proof, YBase)

_P = Formatter.PLAIN
_S = Formatter.STEPPED
_BLANK = Param(b"", 0)

MODULE = Module(
    name="stuttr",
    key="STUTTR",
    kind=Kind.DSP_EFFECT,
    category=Category.TRACK, author="ilia-murzinov",
    author_url="https://github.com/ilia-murzinov",
    proof=Proof.HARDWARE,
    proof_note="Ilia's MKII, STUT NS.RMX (latest−SHATTER; BRAIN switch), "
               "21 Oct 2026: empty-project play; every page-1/page-2 knob, "
               "MODE/SYNC, trig splits, two instances/core, engage/release "
               "fades click-free; verify_stuttr",
    doc="Chance grain repeater: grab, hold-loop, reverse/slow modes.",
    menu=MenuEntry(
        # MULTIBCOMP 0x19 — stock null stub, FX2-only; page clone still from
        # DARK REV. Leaves free-pool ids alone.
        fx2_id=0x19,
        replaces="MULTIBCOMP",
        donor_desc=0x400d58b8,
        abbr=b"STUT",
        fullname=b"Stuttr",
        build_tag=False,
    ),
    params=(
        Param(b"SIZE", 64, active=True, formatter=_P,
              doc="grain length ((kn+1)^2 words; FX2 ~0.1..180 ms)"),
        Param(b"RATE", 64, active=True, formatter=_P,
              doc="how often CHNC may attempt a grab (slow left, fast right)"),
        Param(b"CHNC", 0, active=True, formatter=_P,
              doc="0 = never stutter; 127 = always grab on RATE tick"),
        Param(b"HOLD", 64, active=True, formatter=_P,
              doc="after a hit: how long to keep repeating before dry"),
        Param(b"REV", 0, active=True, formatter=_P,
              doc="per-repeat reverse probability (0 = always forward)"),
        Param(b"MIX", 127, active=True, formatter=_P,
              doc="dry/wet of the stutter vs live"),
        Param(b"MODE", 0, 4, active=True, formatter=_S,
              labels=("FWD", "HALF", "QUART", "RND"),
              doc="1x / half / quarter / per-repeat random rate"),
        Param(b"SYNC", 2, 4, active=True, formatter=_S,
              labels=("FREE", "16", "8", "4"),
              doc="divisions of the RATE attempt clock"),
        _BLANK, _BLANK, _BLANK, _BLANK,
    ),
    mode_slot=6,
    dsp=DspSection(
        asm="modules/stuttr/stuttr.asm",
        priority=19,
        bus_role=BusRole.NONE,
        ybase=YBase.NEVER,
        r7_latch_slot=None,
        gate_label=None,
    ),
    # 15,862 words: under the FX2 rule (+$3DFD, #785) so SIDECHAIN_COMPRESSOR's
    # shared-window keybus stays out of the instance ring.
    claims=Claims(stock_instance_buffer=True, buffer_words=15862),
    # Empty-project sequencer stall with SHATTER+STUTTR: S8 (latest) and
    # STUT SH (pair+stock only); Ilia's MKII 21–22 Oct 2026. NS/NH/NB/C8
    # each run. Not buffer overlap (SHATTER is r7-scratch only). Until
    # fixed, the build refuses the pair (CONTRIBUTING selectable-config rule).
    conflicts=(("SHATTER",
                "empty-project sequencer stalls with SHATTER+STUTTR "
                "(HW STUT SH pair+stock and S8, 21–22 Oct 2026); cause open"),),

    harness=Harness(layout_char="0", is_server=False),  # M = VOID
    gates=(Gate("tools/verify/verify_stuttr.py", remix_arg=False),),
    # dear: engaging demo for renders/gates (not the panel defaults)
    dear={"SIZE": 64, "RATE": 64, "CHNC": 127, "HOLD": 64, "REV": 0,
          "MIX": 127, "MODE": 0, "SYNC": 2},
)

