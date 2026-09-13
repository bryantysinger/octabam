# Phoenix

Console-glue saturator insert, port of `JClones_Phoenix.jsfx` (MIT). A
leaky-differentiator highpass feeding a 15-term polynomial waveshaper
(`Phoenix_sat`) **twice** (an x4->x5 feedback-like pass), a one-pole
lowpass smoother, and Input/Output Trim. Chosen after TapeHead
specifically to see how it compared against Fattener's own "too
expensive, aborted" verdict (`HANDOFF.md`): no biquads, no envelope
follower, and (for the JSFX's own `sat_type 0`, Luminescent/Iridescent)
no risky polynomial fit of our own -- JClones already publish those exact
coefficients. **v2** adds the other two saturator shapes (Radiant's 4-term
weighted sine sum, and Luster/Dark Essence's `x*a/exp(|(x*b)^5|)` bump
curve, `sat_type` 1/2), which JClones do NOT hand you as polynomials --
both are fit in this project instead (see Scope). The same 15-term
polynomial running twice per channel means this is *not* cheaper than
TapeHead, just architecturally safer to build.

## Status

**v2 -- all 5 of the JSFX's Type positions now implemented** (v1 shipped
only Luminescent/Iridescent). Went through the same two-stage validation
as v1, extended to the new scope:

- `sim_phoenix.py` (float JSFX port) already covered all 15 Brightness x
  Type combinations; only the sat_type-1/2 fits are new this round.
- `sim_phoenix_fixed_v2.py` extends `FixedPhoenixV1` to all 5 Types:
  uniform `POLY_SHIFT` raised 3->7 (sat_type 1's own fit needs it), A3/
  P20/P24 now real per-Type constants, three new branch-free per-sample
  quantities (G0 blend, Luster's X4_MULT, Luster's Y_SCALE_HALF output
  path -- see `phoenix.asm`'s own header for the complete writeup,
  including a genuinely new headroom overflow this design had to fix:
  v1's `PROCESSING_P24_X32` trick only stayed safe because both its Types
  capped `PROCESSING<=0.25`; Luster's `a3=1.0` broke that assumption).
  Measures **1.83e-2 peak / 1.294% RMS** error against the float
  reference over a full stress sweep (15 Brightness x Type x Process x
  AutoGain x Input Trim x Output Trim x 6 signals) -- this is the
  DESIGN's own idealized figure, before any assembly existed.
- `verify_phoenix_asm_v2.py` (the same instruction-level DSP56300-subset
  interpreter technique v1 introduced, extended to sweep all 5 Types)
  then executed the actual generated `phoenix.asm` text and found **two
  more real bugs**, on top of v1's own two:

  - **A stale-register bug in the shared base-powers computation**,
    present in v1's own already-shipped generator too, not just the new
    v2 code. `P6 (=XC^6)` was computed as `P2*P2` (=P4) a second time
    instead of `P4*P2`: the `y1` register holding "the last squared
    value" was never refreshed after P4 was computed, so the P6 step
    silently reused P2 from before the P4 step. This corrupted P6 for
    EVERY Type (P8/P10/P12 were unaffected -- they reread both operands
    fresh from r7 memory rather than trusting a register), degree-7's own
    composite power, and P14 downstream of it. Invisible in v1 because
    sat_type 0's own degree-7/13/15 coefficients are modest (max ~5.5);
    glaringly visible fitting sat_type 1's much larger ones (degree 11's
    -82.68), where it produced 30-50% peak errors -- which is what
    actually surfaced it. **This is very likely the real explanation for
    v1's own previously-reported "worse than idealized" 3.1e-2 error**,
    previously attributed only to unmodeled per-term quantization.
    Fixed by capturing P4 into `y1` fresh right after its own store,
    instead of reusing a register left over from the P4 computation.
  - **A boosted value (`TRUE_X3`) stashed to plain r7 memory** in the new
    v2 code -- exactly the same class of bug ("never store a boosted
    value to r7/plain-register") v1's own session already found and fixed
    once, for `TRUE_X2`/`X5_INPUT`. The new X3 blend computed the safe,
    /32-scale `X3S_BY32`, immediately `asl`'d it to true scale (which can
    exceed +/-1), and stored THAT to a plain 24-bit cell before reloading
    it a few instructions later -- silently wrapping (mod 2.0) whenever
    `|X3S_BY32|>=1/32`. Fixed the same way v1 fixed its own instance:
    stash the safe value, redo the `asl` fresh at the one use site.

  With both fixed, the same sweep (2160 trials: 5 Types x 3 Brightness x
  3 Process x 2 Auto Gain x 3 Input Trim x 2 Output Trim x 4 signals)
  finds a worst peak error of **5.9e-4** against `FixedPhoenixV2` (worst
  case: Radiant, Gold, Process 100%, Auto Gain off, Input Trim -10dB,
  Output Trim +6dB, a step signal) -- smaller than v1's own real,
  hardware-measured 3.1e-2, consistent with that older number having
  largely been the P6 bug's own signature rather than pure quantization
  noise.

**Not yet run through the real `dsp_asm`/`dsp_host` toolchain, `build_bus.py`,
`cycle_count.py`, or `selftest.py`** for the v2 changes specifically (this
session still has file stage/read/commit only, no `device_bash`). v1's own
three real build-failure rounds (invalid/colliding `fx2_id`, over-long
`Param.name`s, over-long doc strings -- all fixed, see git history / the
module docstring) are NOT expected to recur, since v2 doesn't touch
`menu=`/param *names* (only `TYPE`'s range 2->5 and some doc text, both
re-checked against the same 90-char/label-length limits that caught the
v1 failures -- see Parameters below). Run `make check REMIX=phoenix_test`
and paste the result back before trusting this further -- same bar every
module before this one was held to, and the same thing that caught v1's
own two real asm-logic bugs.

**Per-channel instruction count** (a rough proxy for cycle cost, not the
real word-accurate figure `cycle_count.py` reports -- unavailable in this
session): 327 instruction lines per `phoenix_l`/`phoenix_r` call in v2,
vs. 315 in v1 (regenerated fresh from `gen_phoenix_asm.py` for this
comparison, byte-identical to what's already on the user's machine) -- a
~+3.8% increase for 3x the Type coverage, because the new per-sample math
(G0 blend, X4_MULT scale, Y_SCALE_HALF path) mostly displaces v1's own
hardcoded-equivalent operations rather than adding net-new ones. **v1's
own measured 963 cycles/sample was already flagged as OVER the
worst-one-core budget by -4,584 cycles** (see below) -- a ~4% instruction
increase does not resolve that, and only `cycle_count.py`'s own real
number (not this line-count proxy) actually decides it.

### v1 history (unchanged, kept for context)

Three real rounds, each fixing a genuine bug the previous one couldn't
see:

- **Round 1**: `fx2_id=0x20` was invalid outright (schema.py caps the field
  at `0x1f`) and, worse, every valid non-stock id was already claimed by
  another module -- a real, total collision. Fixed by replacing stock
  SPATIALIZER (`0x05`, the "stereo imager") via `MenuEntry(replaces=...)`,
  the user's own call once an FX1 slot was confirmed not to be a separate
  id space (FX1/FX2 share one dispatch table, per `schema.py`'s own
  `STOCK_FX2_IDS` comment).
- **Round 2**: `Param.name` is capped at 6 bytes; the first draft's
  `IN TRIM`/`OUT TRIM`/`PROCESS`/`AUTOGAIN` all exceeded it (and used
  spaces, off this project's own convention of single abbreviated words).
  Renamed to `INTRIM`/`OUTTRM`/`PROC`/`AUTOGN`; `BRIGHT`'s `SAPPHIRE` and
  `TYPE`'s `LUMINSCNT`/`IRIDESCNT` labels were also shortened to match the
  6-byte precedent TapeHead's own labels set (not itself a build error --
  schema.py has no label-length check -- just risk reduced proactively).
- **Round 3**: this got the build and dispatch wiring all the way through
  (`build_bus.py` placed the code in both payloads, wired SPATIALIZER's id
  to it on both FX1 and FX2, and `cycle_count.py` confirmed zero `bsr`
  straight-line violations). It then failed `selftest.py`'s "every drawn
  knob has a doc" check: help row docs are capped at 90 chars, and `PROC`
  (108), `BRIGHT` (92) and `TYPE` (170, the worst by far) all exceeded it.
  Shortened all three to fit.

**A real, non-blocking concern surfaced by `cycle_count.py`'s own report,
worth flagging loudly rather than burying:** Phoenix measured **963
cycles/sample** for one L+R call pair (v1) -- and the worst-one-core
projection (8 FX2 slots each running Phoenix) came to 7,704 cycles against
~3,120 usable after stock's own overhead, a shortfall of -4,584, printed as
"OVER the arithmetic ceiling." `cycle_count.py` treated this as
informational for `phoenix_test` specifically (a two-module remix, not one
of the real swept configurations), which is why it didn't fail `make
check` -- but it is the numeric confirmation of what the module docstring
already warned: running the same 15-term polynomial through `Phoenix_sat`
**twice** per channel is genuinely expensive. Whether this is viable at
all in a real multi-module remix is still unmeasured (see Open) and v2's
own ~+4% instruction growth does not resolve it.

MEASURED (Python):
- `sim_phoenix.py` -- float JSFX port, all 5 Types now exercised.
- `sim_phoenix_fixed.py` -- v1's fixed-point DESIGN (Luminescent/
  Iridescent only): 3.8e-5 peak / 0.006% RMS vs. float.
- `sim_phoenix_fixed_v2.py` -- v2's fixed-point DESIGN (all 5 Types):
  1.83e-2 peak / 1.294% RMS vs. float.
- `verify_phoenix_asm.py` -- v1's asm-level check: 3.1e-2 real worst-case
  error (very likely largely the P6 bug described above, not pure
  quantization -- v1's own asm has NOT been regenerated/re-verified this
  round, since v2's `phoenix.asm` supersedes it entirely).
- `verify_phoenix_asm_v2.py` -- v2's asm-level check: 5.9e-4 real
  worst-case error, after fixing both new-found bugs.

INFERRED (reasoned from established project fact, not independently
tested for Phoenix's specific mpy sites):
- Every mpy places the operand that can be negative first and a guaranteed
  non-negative magnitude second, with ONE new, explicitly-flagged
  exception in v2: 4 of the 15 polynomial coefficient slots (degrees 5,
  11, 13, 15) have a sign that differs between `sat_type 2` and `sat_type
  0/1`, so the sign can no longer be resolved by choosing add-vs-subtract
  at code-generation time (one shared instruction sequence serves every
  Type). For exactly these 4 slots the stored r7 value is the SIGNED
  coefficient itself, and the accumulate step is an unconditional `add` --
  the first mpy site in this project where NEITHER operand's sign is fixed
  at code-generation time. Flagged, not silently trusted (see
  `gen_phoenix_asm_blocks_v2.py`'s own header for the full reasoning);
  standard DSP `mpy` semantics (plain signed x signed multiply) give no
  specific reason to expect trouble, and `verify_phoenix_asm_v2.py`'s own
  sweep (which models mpy this way already) found no anomaly traceable to
  it, but it hasn't been exercised by any prior module and needs the same
  real-hardware confirmation as everything else here.
- `poly6`'s coefficient slot (`y0`) can be negative here too (both Input
  Trim's and Output Trim's own fitted p4 are) -- copied unmodified from
  tapehead.asm's own poly6 (itself from fattener.asm), which has the same
  open item: neither CLAUDE.md's mpy-trap list nor Fattener's comments
  confirm that specific pair against the mpysu issue.
- The branchless double-bound clamp used before every `Phoenix_sat` call
  is `sim_phoenix_fixed.py`'s OWN instance (unchanged in v2, same bounds
  reused for all 3 sat_types), verified against 600k random trials.

## Parameters

| slot | name | what it does |
|---|---|---|
| 0 | INTRIM | input trim, continuous -10..+10dB (poly6 fit); 64 = JSFX default 0dB |
| 1 | PROC | process amount, continuous 0..100% (PROCESSING=t*A3, A3 per-type); 0 = JSFX default 0% |
| 2 | OUTTRM | output trim, continuous -6..+6dB (poly6 fit); 64 = JSFX default 0dB |
| 3 | BRIGHT | 3-way select: OPAL / GOLD / SAPPHR (fixed HPF/LPF corner, exact); 1 = JSFX default GOLD |
| 4 | TYPE | 5-way select: LUMIN / IRIDES / RADIAN / LUSTER / DARKES (all 5 JSFX positions); 1 = JSFX default IRIDESCENT |
| 5 | AUTOGN | OFF / ON, compensating gain quadratic vs. Process; 0 = JSFX default OFF |

`TYPE`'s range grew from v1's `(1, 2)` to `(1, 5)` and its labels from 2 to
5 (`RADIAN`/`LUSTER`/`DARKES` added, all kept to the same <=6-byte
precedent as `LUMIN`/`IRIDES`); `PROC`'s doc was reworded since
`PROCESSING=t*A3` no longer has one universal `A3` value. Every other
param is textually unchanged from v1.

## Scope

**v2 implements all 5 Types.** Luminescent and Iridescent (JSFX Type
positions 0/1) use `sat_type 0` -- the hand-given 15-term polynomial
JClones publish directly, unchanged from v1. Radiant (position 2) uses
`sat_type 1`, a 4-term weighted sine sum; Luster and Dark Essence
(positions 3/4) use `sat_type 2`, `x*a/exp(|(x*b)^5|)`. Neither is given
as a polynomial by JClones, so both are FIT in this project:
`sim_phoenix_fixed_v2.py` fits each as a degree-15 ODD least-squares
polynomial (only odd powers -- both are measured exactly odd functions)
over `[-1, Q123_MAX]`, the SAME domain `sat_type 0` already clamps to.
That choice is deliberate, not a shortcut: a wider fit domain (tried up to
+/-3.0, and Chebyshev bases up to degree ~41) is genuinely
ill-conditioned for `sat_type 2`'s sharp "bump" shape (13%+ peak error at
degree 15 over +/-2.0, WORSE at higher degrees -- a real Runge-phenomenon
finding), and separately, any clamp bound above 1.0 true is not
representable as a Q1.23 register constant at all. Max fit error:
2.72e-4 (sat_type 1), 1.29e-3 (sat_type 2).

All three sat_types now share ONE data-driven 15-term evaluator
(`gen_phoenix_asm_blocks_v2.gen_poly_block_v2`) instead of v1's
hardcoded-immediate one, reading each Type's own 15-slot coefficient table
from r7 (populated once per control-tick by the TYPE precompute branch,
`phoenix.asm`'s `type_branch`). `A3`/`P20`/`P24` are no longer identical
across Types (v1's whole reason for baking them in as fixed immediates --
they only happened to match between Luminescent/Iridescent specifically)
and are now real per-Type precomputed constants. `POLY_SHIFT` moved from
v1's 3 to a uniform 7 (sat_type 1's own fit needs `shift>=7`); the added
quantization cost to sat_type 0's own already-shipped coefficients is
negligible (1.05e-4 vs. the prior 8.5e-6, measured not assumed).

## Open

- **`make check REMIX=phoenix_test` needs a fresh run for v2.** It cleared
  all three gates for v1 (see v1 history above); v2 changes `TYPE`'s range
  and some doc text (re-checked against the same limits that caught v1's
  own failures, see Parameters) and regenerates all of `phoenix.asm`, so
  this needs re-confirming, not assumed to still pass. Run it and report
  back; `dsp_asm`/`dsp_host` proper (Gate 3 below) is still unrun from
  this session.
- **The 963 cycles/sample cost (v1, unmeasured whether v2 changed it
  materially) is real and unresolved**: the worst-one-core projection was
  -4,584 cycles over budget. v2's own instruction count only grew ~+3.8%
  per channel, so this is very likely still over budget, but the
  authoritative number is `cycle_count.py`'s, not this session's line-count
  proxy. Before Phoenix goes into any real multi-module station lineup,
  this needs either a burn sweep or a hard look at whether running the
  15-term polynomial twice per channel is viable at all.
- **The 5.9e-4 v2 worst-case error** is measured over a large but still
  non-exhaustive sweep (2160 settings x 4 signals, N=80 samples each) --
  not a proof no other setting or signal pushes it higher. Worth listening
  to specifically at Radiant/Gold/Process=100% (the worst setting found)
  and at hot Input/Output Trim generally before trusting this module.
- **The new signed-coefficient mpy pattern** (degrees 5/11/13/15, see
  Status/INFERRED above) is flagged as genuinely new and unexercised by
  any prior module -- needs real-hardware confirmation, not just this
  session's own interpreter (which necessarily encodes the same
  assumption about `mpy` semantics it's meant to be checking).
- **poly6's negative-coefficient mpy** (`y0` slot): flagged, not resolved,
  same open item TapeHead's own README carries forward from Fattener.
  Unchanged by v2.
- **`fx2_id`/`layout_char` history**: unchanged by v2 (see v1 history
  above and the module docstring) -- still worth re-running `make modules`
  if this tree has grown since.
- **The tapehead.asm clamp discrepancy** (missing second halving) is
  unrelated to Phoenix's own clamp (verified independently, unchanged in
  v2) but is flagged again here since it's still unresolved for whoever
  next touches TapeHead.

## Gates

1. `make check REMIX=phoenix_test` -- the floor (CONTRIBUTING.md). Passed
   all three for v1 (see v1 history); **needs a fresh run for v2** (see
   Open).
2. Once it assembles: disassemble `poly6`'s build and confirm the `y0`
   coefficient slot reads correctly when negative (Input/Output Trim's own
   fitted p4 case), AND confirm the new signed-coefficient mpy sites
   (degrees 5/11/13/15) behave as this session's interpreter assumes --
   neither ever got to real hardware from this session.
3. `send_probe.py --direct --pick PHOENIX --set INTRIM=<n> --set
   PROC=<n> --set OUTTRM=<n> --set BRIGHT=<n> --set TYPE=<n> --set
   AUTOGN=<n> --wav out.wav` (per `docs/remixer/HARNESS.md`), compared to
   `sim_phoenix.py`'s float output for the same settings and input file --
   exercise all 5 TYPE positions this time, with particular attention to
   Radiant (the new worst-case corner found) and the hot-settings corner
   from v1.
4. `tools/verify/verify_phoenix.py` (not yet written) -- predict the
   arithmetic exactly, per `modules/_template/README.md`'s own pattern, and
   refuse to run if the FX2 id it resolves is the SEND fallback rather than
   PHOENIX (same guard `verify_hello.py` uses, per CONTRIBUTING.md).
