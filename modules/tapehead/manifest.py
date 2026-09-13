"""TAPEHEAD -- port of JClones_TapeHead.jsfx (MIT license), a small analog
tape-saturation effect: a 2-state coupled recursion (not a biquad -- see
tapehead.asm's own derivation) driving two cubic "smoothstep" waveshapers
plus a third fixed-gain term, summed and trimmed.

Insert, no bus role -- same shape as Inflator and Fattener. Chosen as the
next conversion candidate specifically because it is smaller than both on
every axis that mattered for Fattener's own "too expensive" verdict (see
HANDOFF.md): no biquads at all (Fattener needed three), no per-sample
transcendental calls (Fattener's tanh needed a fixed-point polynomial
duplicated per channel; TapeHead's smoothstep is a plain cubic), and no
envelope follower. r7 scratch used: $00-$35 (54 words) -- less than
Fattener's 82, in the same range as Inflator's own ~40.

Every design decision is validated numerically first, same working method
as Fattener's own session (see HANDOFF.md, "write assembly + validate
numerically in Python, do not attempt to drive the real dsp_asm/dsp_host
toolchain from this session"): sim_tapehead.py is the float JSFX port,
ground truth; sim_tapehead_fixed.py mirrors tapehead.asm's own scaling/
shift/quantization choices exactly and measures worst peak error 7.3e-5,
worst RMS error 0.003%, against the float reference, across every Color x
Drive x Trim setting and a stress set of impulse/step/sine test signals.
NOT yet run through the real dsp_asm/dsp_host -- this session has file
stage/read/commit only, no device_bash. Run `make check REMIX=tapehead_test`
and report back before trusting this further, same bar Inflator's and
Fattener's own first drafts were held to.

v1 scope, deliberate (see tapehead.asm's header for the full reasoning):
  - Clip is always effectively on (this hardware's Q1.23 format can't
    represent the JSFX's "Clip: off" headroom-above-1.0 mode at all, same
    reasoning as Inflator's CLIP knob) -- and since the JSFX's own default
    is Clip=on, this changes nothing about the default sound. No CLIP
    param is exposed in v1 (unlike Inflator, which kept a CLIP slot that
    just doesn't do anything different yet -- there is no reason here to
    reserve a slot for a mode this hardware cannot represent).
  - Drive and Trim are continuous 128-position knobs (poly6 fits over the
    knob fraction) rather than the JSFX's 10-step/22-step integer sliders
    -- the underlying formula and range are unchanged, only the
    granularity, same choice Inflator/Fattener both made for their own
    continuous-feeling knobs. Color stays a genuine 3-way select (a
    different fixed filter frequency per position).

OPEN, flagged in tapehead.asm's own header (note 2): poly6's coefficient
slot is `y0`, which can be negative (DRIVE16's fitted p4 is) -- this
mirrors fattener.asm's own poly6 mpy order exactly, but neither
CLAUDE.md's mpy-trap list nor Fattener's own comments confirm that
specific pair against the mpysu issue. Disassemble poly6's build before
trusting it, per CLAUDE.md's rule for any new mpy whose second operand can
go negative.
"""

from remix.schema import (BusRole, DspSection, Formatter, Harness, Kind,
                          MenuEntry, Module, Param, YBase)

MODULE = Module(
    name="tapehead",
    key="TAPEHEAD",
    kind=Kind.DSP_EFFECT,
    doc="Analog tape saturation port of JClones_TapeHead (2-state recursion, cubic waveshapers).",

    menu=MenuEntry(
        # Reusing FATTENER's own placeholder id at the user's explicit
        # instruction -- the fattener/ module is being removed, freeing
        # 0x1f. `make modules` is the actual arbiter (same caveat every
        # manifest in this project carries): confirm 0x1f is actually free
        # -- i.e. that modules/fattener/ is gone from the tree -- before
        # building this alongside anything else.
        fx2_id=0x1f,
        donor_desc=0x400d5726,        # SPRING REV -- same reasoning as
                                      # Inflator/Fattener: every page-1 slot
                                      # actually used is written explicitly
                                      # below, so the donor's own empty
                                      # slots don't matter
        abbr=b"TAPE",                 # 4 chars
        fullname=b"TAPEHEAD",         # 8 of 12 usable bytes
        build_tag=False,
    ),

    params=(
        # ---- page 1 (3 of 6 slots used -- matches the JSFX's own 4
        # sliders minus Clip, which v1 doesn't expose, see module doc) ---
        Param(b"DRIVE", 36, 128, active=True, formatter=Formatter.PLAIN,
              doc="tape drive amount, continuous (poly6 fit of JSFX drive "
                  "1..10); 36 ~= JSFX default 3.5"),
        Param(b"TRIM", 18, 128, active=True, formatter=Formatter.PLAIN,
              doc="output trim, continuous 0..-21dB (poly6 fit); 18 = "
                  "JSFX default -3dB"),
        Param(), Param(), Param(), Param(),   # page 1 slots 2-5 blank (a select may not sit on page 1)
        # ---- page 2: knob . select . ... -- COLOR on slot 7 (13 Sep 2026) ---
        Param(),
        Param(b"COLOR", 0, 3, active=True, formatter=Formatter.STEPPED,
              labels=("NORMAL", "MEDIUM", "BRIGHT"),
              doc="fixed filter frequency 2100 / 3680 / 5000 Hz; JSFX default NORMAL"),
        Param(), Param(), Param(), Param(),
    ),

    dsp=DspSection(
        asm="modules/tapehead/tapehead.asm",
        # After Inflator's 12 -- reusing Fattener's own slot in the
        # ordering since that module is being removed. BYTE-LOAD-BEARING
        # once this sits in a real remix; check the ledger (`make modules`)
        # rather than trusting this number if it collides.
        priority=13,
        bus_role=BusRole.NONE,
        ybase=YBase.NEVER,            # no absolute Y anywhere in the source
        r7_latch_slot=None,           # init: unconditionally zeros the 4
                                      # persistent state words ($00-$03)
                                      # every time the effect is (re)selected
                                      # -- same reasoning as Inflator/
                                      # Fattener, no warm-up tag needed
        gate_label=None,
    ),

    # "4" -- reusing Fattener's own guess, with the same caveat Fattener's
    # manifest carried: NOT independently verified. Run `make modules` and
    # grep every manifest's layout_char (both modules/*/manifest.py AND
    # tools/remix/stock.py) before trusting this, exactly the check that
    # caught Inflator's original "I" colliding with stock LO-FI.
    harness=Harness(layout_char="4", is_server=False),
)
