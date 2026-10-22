"""SHATTER -- multi-stage crush with chaotic feedback.

A per-track insert: DRV into a wavefolder, hard or soft clip, combined
bit/sample-rate crush, then a feedback loop with a tone shelf. MODE CHAOS
flips feedback polarity from a free-running ramp. MIX 0 is bit-exact dry.
"""

from remix.schema import (BusRole, Category, DspSection, Formatter, Gate, Harness,
                          Kind, MenuEntry, Module, Param, Proof, YBase)

_P = Formatter.PLAIN
_S = Formatter.STEPPED
_BLANK = Param(b"", 0)

MODULE = Module(
    name="shatter",
    key="SHATTER",
    kind=Kind.DSP_EFFECT,
    category=Category.TRACK, author="ilia-murzinov",
    author_url="https://github.com/ilia-murzinov",
    proof=Proof.HARDWARE,
    proof_note="Ilia's MKII, remix shatter BUILD S6 (SHATTER S6.RMX), 21 Oct 2026: "
               "every page-1/page-2 knob exercised (CLIP open + FDBK for MODE/"
               "TONE/RATE); verify_shatter",
    doc="Crush insert: fold, clip, bit/SRR crush, chaotic feedback.",
    menu=MenuEntry(
        fx2_id=0x0a,
        donor_desc=0x400d58b8,        # DARK REV
        abbr=b"SHTR",
        fullname=b"Shatter",
        build_tag=False,
    ),
    params=(
        Param(b"DRV", 0, active=True, formatter=_P,
              doc="pre-gain on dry (~×9 at 127); 0 = unity; fb not driven"),
        Param(b"FOLD", 0, active=True, formatter=_P,
              doc="wavefolder; 0 = unity (skip); higher = more fold (never quieter)"),
        Param(b"CLIP", 0, active=True, formatter=_P,
              doc="clip threshold (0 = open, 127 = brick wall)"),
        Param(b"CRSH", 0, active=True, formatter=_P,
              doc="combined bit-depth and sample-rate crush"),
        Param(b"FDBK", 0, active=True, formatter=_P,
              doc="feedback around fold/clip/crush; CHAOS flips its polarity"),
        Param(b"MIX", 127, active=True, formatter=_P,
              doc="dry/wet; 0 = exact passthrough"),
        Param(b"MODE", 0, 3, active=True, formatter=_S,
              labels=("HARD", "SOFT", "CHAOS"),
              doc="HARD hard clip; SOFT cubic soft clip; CHAOS polarity flips"),
        Param(b"TONE", 64, active=True, formatter=_P,
              doc="feedback loop shelf: 0 dark, 127 bright"),
        Param(b"RATE", 64, active=True, formatter=_P,
              doc="CHAOS polarity flip rate; ignored in HARD/SOFT"),
        _BLANK, _BLANK, _BLANK,
    ),
    mode_slot=6,
    dsp=DspSection(
        asm="modules/shatter/shatter.asm",
        priority=18,
        bus_role=BusRole.NONE,
        ybase=YBase.NEVER,
        r7_latch_slot=None,
        gate_label=None,
    ),
    harness=Harness(layout_char="4", is_server=False),  # B = stock MULTIBCOMP

    gates=(Gate("tools/verify/verify_shatter.py", remix_arg=False),),
    dear={"DRV": 127, "FOLD": 127, "CLIP": 100, "CRSH": 100, "FDBK": 80,
          "MIX": 127, "MODE": 2, "TONE": 100, "RATE": 100},
)
