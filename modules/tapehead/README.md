# TapeHead

Analog tape-saturation insert, port of `JClones_TapeHead.jsfx` (MIT). A
2-state coupled recursion (not a biquad -- see `tapehead.asm`'s header for
the exact derivation) driving two cubic "smoothstep" waveshapers plus a
third fixed-gain term, summed and trimmed. Chosen as the next conversion
after Inflator specifically because it has none of what made Fattener too
expensive (HANDOFF.md): no biquads, no per-sample transcendental calls, no
envelope follower.

## Status

**Third draft, twice run through the real toolchain, twice failed at the
same gate.** This session has file stage/read/commit only (no
`device_bash`), so the user runs `make check` on their own machine and
pastes the result back. Both real runs got past the build and the ledger,
then failed on the identical line: `python3 tools/build/cycle_count.py` ->
`tapehead: bsr callee tapehead_l is not straight-line`.

- Round 1 (first draft): `tapehead_l`/`tapehead_r`/`smoothstep` used
  ordinary forward branches for two clamps. Read the error as "conditional
  branches are the problem" and made them branchless (the `(A+B+/-|A-B|)/2`
  max/min identity, `fattener.asm`'s own proven d8-clamp sequence) -- but
  left `tapehead_l` calling `bsr smoothstep` and a new `bsr clamp_y3`,
  reasoning a call to a genuinely straight-line callee would be fine.
- Round 2: identical error, on the identical callee. That disproves the
  round-1 reasoning: the checker does not recurse into a nested `bsr`
  target to see whether *it* is straight-line -- a callee reached from the
  sample loop may contain **no control-transfer instruction of any kind**,
  not even a call to something itself straight-line. This is what
  Fattener's own session's HANDOFF.md already said ("inlined tanh_sat per
  channel for that reason"), which should have been taken literally the
  first time.
- Round 2 fix (this draft): `smoothstep` and the y3 output-clamp are no
  longer separate `bsr`'d routines at all -- their bodies are inlined
  directly into `tapehead_l`/`tapehead_r` (`smoothstep` twice per channel,
  the clamp once per channel), so both channel routines are now single
  unbroken straight-line blocks ending in one `rts` each, no exceptions.
  `poly6` keeps its own `bsr` (called only from the once-per-block
  precompute, outside the sample loop, so it was never subject to this
  rule).

Not yet re-run a third time -- everything below is either MEASURED in
Python or INFERRED from that plus this project's existing, hardware-verified
modules (Inflator) and documented traps (CLAUDE.md).

MEASURED (Python):
- `sim_tapehead.py` is a line-for-line float port of the JSFX. `SR=44100`
  is assumed throughout, matching `inflator.asm`'s own header comment
  ("240 Hz @ 44.1k") -- this project's only other stated sample-rate fact.
- The state recursion (y1, y2) is linear and time-invariant; its exact
  worst-case bound for any input sequence bounded by +/-1 is the L1 norm
  of its impulse response, computed analytically per Color setting:
  |y1| <= 1.40-1.46, |y2| <= 1.40-1.95 depending on Color (bright is
  worst). Confirmed stable for all three Colors (state-transition matrix
  eigenvalues inside the unit circle, spectral radius 0.49-0.76).
- `sim_tapehead_fixed.py` implements the exact fixed-point design
  `tapehead.asm` uses (same shifts, same quantization-by-truncation at
  every stored value) and compares it end to end against the float
  reference across every Color x Drive x Trim combination against
  impulse/step/220 Hz/1 kHz/4 kHz/8 kHz/12 kHz test signals: worst peak
  error 7.3e-5, worst RMS error 0.003%. Headroom margins checked
  explicitly at every point a value becomes an mpy operand or leaves a
  channel routine -- none exceed ~50% of the representable range for any
  setting/signal tried (see that file's own printed report).

INFERRED (reasoned from established project fact, not independently
tested):
- Every mpy places the operand that can be negative first and a
  guaranteed non-negative magnitude second (k3 and g3 are fixed constants
  that are *always* negative here, so their magnitude is stored and the
  sign applied afterward as a subtract) -- the same discipline Inflator's
  onepole/waveshape headers describe as confirmed by direct testing on
  *that* module. Applying the same discipline here is inference, not a
  fresh confirmation for TapeHead's specific mpy sites.
- `smoothstep` and the y3 output-clamp are now fully inlined (not merely
  branchless) directly inside `tapehead_l`/`tapehead_r`, which contain zero
  `bsr`/`bra`/`bcc` of any kind. This is no longer inference: two real
  `make check REMIX=tapehead_test` runs both failed `cycle_count.py` with
  the identical complaint (`bsr callee tapehead_l is not straight-line`),
  the second one specifically disproving the intermediate design (a `bsr`
  to a genuinely straight-line `clamp_y3`/`smoothstep`) that round 1 had
  tried. This confirms Fattener's own session's conclusion (HANDOFF.md) in
  its strongest form -- zero further control transfer of any kind, not just
  no conditional branches -- over Inflator's apparent (but evidently never
  checked) practice of branching inside `onechan_l`/`waveshape`.
- poly6's coefficient slot (`y0`) can be negative (`DRIVE16`'s fitted p4
  is) -- copied from fattener.asm's own poly6 mpy order, which has the
  same shape. Neither CLAUDE.md's mpy-trap list nor Fattener's comments
  confirm that pair against the mpysu issue specifically.

## Parameters

| slot | name  | what it does |
|---|---|---|
| 0 | DRIVE | tape drive amount, continuous 0-127 (poly6 fit of the JSFX's drive_logical 1..10, default raw 36 ~= JSFX default 3.5) |
| 1 | TRIM  | output trim, continuous 0-127 mapping to 0..-21dB (poly6 fit, default raw 18 = JSFX default -3dB) |
| 2 | COLOR | 3-way select: NORMAL (2100 Hz) / MEDIUM (3680 Hz) / BRIGHT (5000 Hz), default NORMAL |

No Clip param in v1 -- see the module doc in `manifest.py` for why (this
hardware's Q1.23 format can't represent the JSFX's "off" mode at all, and
the JSFX's own default is already the mode this module always runs in).

## Open

- **Not fully run through `dsp_asm`/`dsp_host` yet.** This is the actual
  bar for "correct" on this project (CONTRIBUTING.md). Two real runs both
  failed `cycle_count.py` on the same complaint (see Status); the second
  draft's partial fix (bsr to a straight-line callee) turned out to still
  be wrong, and this third draft's full-inlining fix has not yet been run
  at all. Run `make check REMIX=tapehead_test` again and report back what
  fails first, if anything.
- ~~The bsr-callee branch-tolerance question~~ -- RESOLVED, in its
  strongest form (see Status): a bsr callee reached from the sample loop
  may contain no control-transfer instruction of any kind, not even a call
  to a genuinely straight-line routine -- confirmed by two consecutive
  `make check` runs, the second one specifically ruling out the weaker
  "no conditional branches" reading the first fix assumed. `smoothstep` and
  the y3 output-clamp are now fully inlined per channel, not merely
  branchless.
- **poly6's negative-coefficient mpy** (`y0` slot, DRIVE16's p4): flagged,
  not resolved. Disassemble the built `poly6` calls once this assembles,
  per CLAUDE.md's own rule for any new mpy whose second operand can go
  negative.
- **`fx2_id=0x1f` and `layout_char="4"` are Fattener's own placeholders**,
  reused here because that module is being removed. Both need `make
  modules` run against the tree *after* `modules/fattener/` is actually
  gone, not assumed free from this file alone.
- **Headroom margins are measured against a stress *set*, not a proof.**
  The state's worst-case bound (L1 norm) *is* an exact analytic proof for
  the recursion alone; the smoothstep/combine-stage margins are measured
  across a specific signal set (impulse, step, six sine frequencies) at
  every Color x Drive x Trim combination, which is thorough but not
  exhaustive -- unlike the state bound, nobody has proven these can't be
  pushed further by some other input shape.

## Gates

1. `make check REMIX=tapehead_test` -- the floor (CONTRIBUTING.md). Not
   run yet from this session.
2. Once it assembles: disassemble `poly6`'s build and confirm the `y0`
   coefficient slot reads correctly when negative (the DRIVE16 p4 case).
3. `send_probe.py --direct --pick TAPEHEAD --set DRIVE=<n> --set
   TRIM=<n> --set COLOR=<n> --wav out.wav` (per `docs/remixer/HARNESS.md`,
   same tool Fattener's own handoff named) against a few DRIVE/COLOR
   combinations, compared to `sim_tapehead.py`'s float output for the same
   settings and input file -- the actual bar this module hasn't cleared
   yet.
4. `tools/verify/verify_tapehead.py` (not yet written) -- predict the
   arithmetic exactly, per `modules/_template/README.md`'s own pattern,
   and refuse to run if the FX2 id it resolves is the SEND fallback
   rather than TAPEHEAD (same guard `verify_hello.py` uses, per
   CONTRIBUTING.md).
