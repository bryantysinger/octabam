"""PHOENIX -- port of JClones_Phoenix.jsfx (MIT license), an asymmetric
multi-stage "console glue" saturator: a leaky-differentiator highpass
feeding a 15-term polynomial waveshaper TWICE (a feedback-like pass), a
one-pole lowpass smoother, and Input/Output Trim.

Insert, no bus role -- same shape as Inflator/TapeHead. Chosen after
TapeHead specifically to compare against Fattener's own "too expensive,
aborted" verdict (HANDOFF.md): Phoenix has none of Fattener's three biquads
or its envelope follower, and (unlike Fattener's own risky curve-fit tanh
approximation) its saturator is a polynomial JClones hand-picked and
published directly (sat_type 0), fit here ourselves for the other two
saturator shapes (sat_type 1/2, see below). It is NOT cheaper than
TapeHead, though: the same 15-term polynomial runs through Phoenix_sat
TWICE per channel (an x4->x5 feedback-like pass), where TapeHead's own
smoothstep is a plain cubic -- see phoenix.asm's own header for the exact
r7 scratch comparison and the still-open per-core cycle budget concern.

v2: all 5 of the JSFX's Type positions are now implemented (v1 shipped
only Luminescent/Iridescent, both sat_type 0 -- see phoenix.asm's own
header, point "WHAT'S NEW SINCE v1", for the complete reasoning). Radiant
(sat_type 1, a 4-term weighted sine sum) and Luster/Dark Essence (sat_type
2, x*a/exp(|(x*b)^5|)) are NOT given as polynomials by JClones the way
sat_type 0 is -- both are fit here, as degree-15 odd polynomials over the
same [-1, Q123_MAX] domain sat_type 0 already clamps to (max fit error
2.72e-4 and 1.29e-3 respectively; see sim_phoenix_fixed_v2.py's header for
why that specific domain, not a wider one, was the right call both
numerically and for Q1.23 representability). All three sat_types now share
ONE data-driven 15-term evaluator (gen_phoenix_asm_blocks_v2.py's
gen_poly_block_v2) instead of v1's hardcoded-immediate one; A3/P20/P24 are
now real per-Type precomputed constants instead of baked-in immediates
(they were only ever identical between Luminescent/Iridescent, the
coincidence v1's own scope relied on).

Every design decision is validated numerically first, same working method
as every prior module (see HANDOFF.md): sim_phoenix.py is the float JSFX
port (all 15 Brightness x Type combinations, ground truth, now including
the sat_type 1/2 fits); sim_phoenix_fixed_v2.py is the fixed-point DESIGN
extending v1's own FixedPhoenixV1 to all 5 Types, measuring 1.83e-2 peak /
1.294% RMS error against the float reference over a full stress sweep.
THEN, same as v1: verify_phoenix_asm_v2.py is a DSP56300-subset interpreter
that EXECUTES phoenix.asm's own generated instruction text (not a hand
re-derivation) and compares it sample-by-sample against FixedPhoenixV2.
This caught TWO real bugs this round -- a stale-register error in the
shared base-powers computation that silently corrupted P6/P14 for every
Type (present in v1's own shipped generator too, invisible there because
sat_type 0's own affected coefficients are small, and very likely the real
explanation for v1's previously-reported "worse than idealized" 3.1e-2
error), and a boosted intermediate value (TRUE_X3) stashed to plain r7
memory instead of staying resident in a register until consumed -- the
exact same class of bug (silently wrapping past +/-1) v1's own session
already found and fixed once for TRUE_X2/X5_INPUT. See phoenix.asm's own
STATUS section for the complete writeup. With both fixed, the real
(asm-level) worst-case error measured is 5.9e-4 -- smaller than v1's own
hardware-measured 3.1e-2, consistent with that older figure having largely
been the P6 bug's own signature. NOT yet run through the real dsp_asm/
dsp_host toolchain -- this session has file stage/read/commit only, no
device_bash. Run `make check REMIX=phoenix_test` and report back before
trusting this further, same bar every module before this one was held to.

FX2 id history: the first draft guessed fx2_id=0x20, which is simply
invalid (schema.py caps the field at 0x1f) and, worse, every valid non-
stock id (0x04-0x1f minus STOCK_FX2_IDS, 13 ids) is already claimed by an
existing module -- a real, total collision, not a near miss. Per the
user's direction, Phoenix now REPLACES stock SPATIALIZER (0x05) instead
(the "stereo imager" -- see menu= below), the same mechanism spectrum/
modulation/character use for FILTER/CHORUS/LO-FI. An "FX1 slot" was not a
way around this: schema.py's own STOCK_FX2_IDS comment confirms FX1 and
FX2 share one dispatch table indexed by the same raw id, so there is no
separate FX1 id space to place a module into. Unchanged by the v2 scope
expansion (v2 still replaces the same stock id, no new Claims).
"""

from remix.schema import (BusRole, DspSection, Formatter, Harness, Kind,
                          MenuEntry, Module, Param, YBase)

MODULE = Module(
    name="phoenix",
    key="PHOENIX",
    kind=Kind.DSP_EFFECT,
    doc="Console-glue saturator port of JClones_Phoenix (highpass into a 15-term poly waveshaper, twice, plus a one-pole smoother).",

    menu=MenuEntry(
        # 0x20 was a guess and wrong outright -- schema.py caps fx2_id at
        # 0x1f (0x00-0x03 are stock's own "no effect" synonyms). Worse, a
        # full survey of every modules/*/manifest.py in this tree (`make
        # check` failing is what prompted it) found ALL THIRTEEN non-stock
        # ids in the valid 0x04-0x1f range already claimed (busdelay 0x06,
        # busverb 0x07, send 0x09, warpfold 0x0a, ripple 0x0b, streamz
        # 0x0e, bodeshift 0x0f, rungs 0x17, nimbus 0x1a, hello 0x1b,
        # nimbuslite 0x1d, inflator 0x1e, tapehead 0x1f) -- zero free slots,
        # not a near miss. Per the user's own call, Phoenix instead REPLACES
        # stock SPATIALIZER (0x05, tools/remix/stock.py's "stereo imager" --
        # its own doc string is literally "Stock stereo spatializer"), the
        # same mechanism spectrum/modulation/character already use for
        # FILTER/CHORUS/LO-FI. This was also the answer to "can it go on an
        # FX1 slot instead?" -- schema.py's own STOCK_FX2_IDS comment states
        # the init/process dispatch tables are SHARED BETWEEN FX1 AND FX2
        # (indexed by the same raw id), so there is no separate FX1 id space
        # to dodge into; a `replaces` module answers on both menus at once
        # regardless, which is a wash here since Phoenix has no FX1-only
        # ambition of its own. SPATIALIZER allocates an instance buffer
        # (Claims.stock_instance_buffer) but Phoenix touches no buffer at
        # all (bus_role=NONE, no Claims below), so replacing a buffer-using
        # stock effect costs nothing extra -- same as if a buffer-free stock
        # id had been free instead.
        fx2_id=0x05,
        replaces="SPATIALIZER",
        donor_desc=0x400d5726,        # SPRING REV -- same reasoning as
                                      # Inflator/TapeHead: every page-1 slot
                                      # actually used is written explicitly
                                      # below, so the donor's own empty
                                      # slots don't matter. Not SPATIALIZER's
                                      # own descriptor -- modulation/
                                      # character both pick their donor_desc
                                      # independently of which stock id they
                                      # replace, same reasoning applies here.
        abbr=b"PHNX",                 # 4 chars
        fullname=b"PHOENIX",          # 7 of 12 usable bytes
        build_tag=False,
    ),

    params=(
        # ---- page 1 (all six slots used -- matches the JSFX's own 6
        # sliders exactly; v2 now covers all 5 of TYPE's own positions)
        #
        # Names fixed after a real build failure: schema.py's Param caps
        # `name` at 6 bytes (no error for it exists until construction, so
        # the first draft's "IN TRIM"/"OUT TRIM"/"PROCESS"/"AUTOGAIN" all
        # slipped past review) and, separately, this project's own
        # convention (every modules/*/manifest.py Param name grepped, none
        # over 6, none with a space) is to abbreviate rather than truncate
        # blindly -- FDBK, DPTH, MRAT and similar. Renamed accordingly:
        # IN TRIM->INTRIM, PROCESS->PROC, OUT TRIM->OUTTRM,
        # AUTOGAIN->AUTOGN. BRIGHT and TYPE were already <=6 and unchanged.
        Param(b"INTRIM", 64, 128, active=True, formatter=Formatter.PLAIN,
              doc="input trim, continuous -10..+10dB (poly6 fit); "
                  "64 = JSFX default 0dB"),
        Param(b"PROC", 0, 128, active=True, formatter=Formatter.PLAIN,
              # doc capped at 90 chars by selftest.py (help row is one
              # line). v2: PROCESSING=t*A3 with A3 now per-Type (was a
              # fixed 0.25 immediate in v1, true only because Luminescent/
              # Iridescent happen to share that value) -- doc reworded
              # rather than left stating the no-longer-universal 0.25.
              doc="process amount, continuous 0..100% (PROCESSING=t*A3, "
                  "per-type); 0=JSFX default 0%"),
        Param(b"OUTTRM", 64, 128, active=True, formatter=Formatter.PLAIN,
              doc="output trim, continuous -6..+6dB (poly6 fit); "
                  "64 = JSFX default 0dB"),
        Param(b"BRIGHT", 1, 3, active=True, formatter=Formatter.PLAIN,
              # Labels have no length check in schema.py, but tapehead's own
              # NORMAL/MEDIUM/BRIGHT (6 chars each) is the longest precedent
              # found across every manifest -- SAPPHIRE (8) was longer than
              # that with nothing to justify the risk, so shortened to match.
              labels=("OPAL", "GOLD", "SAPPHR"),
              # doc shortened from 92 to 74 chars, same 90-char cap as PROC.
              doc="fixed HPF/LPF corner per position (exact, SR=44100); "
                  "1 = JSFX default GOLD"),
        Param(b"TYPE", 1, 5, active=True, formatter=Formatter.PLAIN,
              # v2: all 5 of the JSFX's own Type positions, not just the
              # first 2. RADIAN/LUSTER/DARKES kept to the same <=6-byte
              # precedent as LUMIN/IRIDES (schema.py has no label-length
              # check, but every existing manifest's labels fit 6 bytes).
              labels=("LUMIN", "IRIDES", "RADIAN", "LUSTER", "DARKES"),
              # doc rewritten now that all 5 positions are implemented --
              # the old "v1: 2 of 5" framing no longer applies. Still
              # capped at 90 chars; the full sat_type-1/2 fit story lives
              # in the module docstring and phoenix.asm's own header.
              doc="all 5 JSFX Types now implemented, sat_type/A3/P20/P24 "
                  "per-type; 1=JSFX default IRIDES"),
        Param(b"AUTOGN", 0, 2, active=True, formatter=Formatter.PLAIN,
              labels=("OFF", "ON"),
              doc="compensating gain quadratic vs. Process amount; "
                  "0 = JSFX default OFF"),
        # ---- page 2: none -----------------------------------------------
        Param(), Param(), Param(), Param(), Param(), Param(),
    ),

    dsp=DspSection(
        asm="modules/phoenix/phoenix.asm",
        # After TapeHead's 13 -- BYTE-LOAD-BEARING once this sits in a
        # real remix alongside other modules, so check the ledger (`make
        # modules`) rather than trusting this number if it collides.
        priority=14,
        bus_role=BusRole.NONE,
        ybase=YBase.NEVER,            # no absolute Y anywhere in the source
        r7_latch_slot=None,           # init: unconditionally zeros the 4
                                      # persistent state words every time
                                      # the effect is (re)selected -- same
                                      # reasoning as Inflator/TapeHead, no
                                      # warm-up tag needed
        gate_label=None,
    ),

    # "5" -- confirmed free by grepping layout_char across every
    # modules/*/manifest.py (17 hits: F B S Q 2 4 M D 1 X 3 W N G H R) and
    # every tools/remix/stock.py _stock() call (14 hits: L E J P A C Z O K
    # I Y T U V). Together that is all 26 letters A-Z plus digits 1-4 --
    # zero slack in the alphabet, so "5" is the only thing left, not a
    # further guess. (`make modules` is still the actual arbiter if this
    # tree has since grown a 31st layout_char user.) Unchanged by v2.
    harness=Harness(layout_char="5", is_server=False),
)
