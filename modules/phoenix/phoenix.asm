; ---------------------------------------------------------------------------
; PHOENIX v2 -- octabam module, port of JClones_Phoenix.jsfx (MIT), an
; asymmetric multi-stage "console glue" saturator. v2 EXTENDS v1
; (Luminescent/Iridescent, sat_type 0 only) to ALL 5 Types: Luminescent,
; Iridescent, Radiant, Luster, Dark Essence (sat_type 0/1/2) -- see
; sim_phoenix_fixed_v2.py's own header for the full numerical design this
; file turns into instructions (fits for sat_type 1/2, the uniform
; POLY_SHIFT=7, and the three new branch-free per-sample quantities: the
; G0 x3-blend, Luster's X4_MULT, and the Y_SCALE_HALF output path).
;
; STATUS: v2, generated end-to-end by gen_phoenix_asm_v2.py from the
; validated fixed-point design in sim_phoenix_fixed_v2.py (worst peak error
; 1.83e-2, worst RMS error 1.294% vs. the float JSFX reference sim_phoenix.py,
; across all 15 Brightness x Type combinations x Process x AutoGain x Input
; Trim x Output Trim and a stress signal set -- that figure is the DESIGN's
; own idealized error, before this asm text existed).
;
; Same as v1's own history, this draft then went through
; verify_phoenix_asm_v2.py -- the instruction-level interpreter that
; EXECUTES this file's literal text (not a re-derivation) against
; FixedPhoenixV2 -- across all 5 Types x 3 Brightness x 3 Process x 2 Auto
; Gain x 3 Input Trim x 2 Output Trim x 4 signals (2160 trials). This found
; and fixed TWO real bugs, neither visible from the design-level validation
; or from reading the generator source, exactly the way v1's own two bugs
; were found:
;
;   - **Stale-register bug in the shared base-powers block** (gen_phoenix_
;     asm_blocks_v2.py's gen_poly_block_v2, and this exact same pattern in
;     the ALREADY-SHIPPED v1 generator's gen_poly_block): P6 (=XC^6) was
;     computed as P2*P2 (=P4) a second time instead of P4*P2, because the
;     y1 register used to hold "the last squared value" was never
;     refreshed after P4 was computed -- P4's own store to r7 memory left
;     `a` correct, but the subsequent P6 step reused y1 from BEFORE the P4
;     step (still holding P2), not after. This silently corrupted P6 for
;     EVERY Type (P8/P10/P12 were unaffected -- each rereads its operands
;     fresh from r7 memory rather than trusting a register), degree-7's own
;     composite power (P6*XC), and P14 (=P8*P6) downstream of it. The
;     effect was invisible in v1 because sat_type 0's own degree-7/13/15
;     coefficients are modest (max ~5.5); it became glaringly visible
;     fitting sat_type 1's much larger coefficients (degree 11's -82.68),
;     where it produced 30-50% peak errors -- which is what actually
;     surfaced it. This is very likely the real explanation for v1's own
;     previously-reported "worse than expected" 3.1e-2 measured error,
;     previously attributed only to unmodeled per-term quantization.
;     FIXED by capturing P4 into y1 fresh (via `move a,y1` immediately
;     after P4's own store) instead of reusing a stale register.
;   - **A boosted value stashed to plain r7 memory** (TRUE_X3, in this
;     file's own phoenix_l/phoenix_r): the new X3 blend computes X3S_BY32
;     (safe, /32 scale) then immediately asl #5'd it to TRUE_X3 (which can
;     exceed +/-1 in magnitude) and stashed THAT boosted value to a plain
;     24-bit r7 cell before the X4_PP20 computation, reloading it after --
;     exactly the "never store a boosted value to r7/plain-register" bug
;     this project's own v1 session already named and fixed once (for
;     TRUE_X2/X5_INPUT). Silently wrapped (mod 2.0) on any sample where
;     |X3S_BY32|>=1/32, producing large, input-dependent errors that only
;     showed up test-run-to-test-run depending on signal amplitude -- this
;     is what caused the still-large error after the P6 fix above. FIXED
;     the same way v1 fixed its own instance: stash the SAFE (un-boosted)
;     X3S_BY32 instead, and redo the asl #5 fresh, in-register, at the one
;     use site, never letting the boosted value touch memory.
;
; With BOTH fixed, the same 2160-trial sweep finds a worst peak error of
; **5.9e-4** against FixedPhoenixV2 (worst case: Radiant, Gold, Process
; 100%, Auto Gain off, Input Trim -10dB, Output Trim +6dB, a step signal)
; -- smaller than v1's own real, hardware-measured 3.1e-2, and consistent
; with that figure having been the P6 bug's own signature all along. Not
; yet run through the real dsp_asm/dsp_host toolchain -- this session has
; file stage/read/commit only, no device_bash. Run `make check
; REMIX=phoenix_test` and paste the result back, same workflow as v1 and
; every module before it.
;
; Per-channel instruction count (a rough proxy for cycle cost, not the
; real word-accurate figure `cycle_count.py` reports -- that tool is not
; available in this session): 327 instruction lines per phoenix_l/
; phoenix_r call here, vs. 315 in the currently-shipped v1 (regenerated
; fresh from gen_phoenix_asm.py for this comparison, byte-identical to
; what's already on the user's machine) -- a ~+3.8% increase for 3x the
; Type coverage, not the much larger jump the new per-sample math (G0
; blend, X4_MULT scale, Y_SCALE_HALF path) might suggest, because it
; mostly displaces v1's own hardcoded-equivalent operations rather than
; adding net-new ones. v1's own README already flagged its measured 963
; cycles/sample as OVER the worst-one-core budget by -4,584 cycles before
; this change; a ~4% instruction-count increase does not resolve that, and
; `cycle_count.py`'s own real number (not this line-count proxy) is what
; actually decides it -- see this module's README for the full writeup.
;
; WHAT'S NEW SINCE v1 (read sim_phoenix_fixed_v2.py's header for the full
; numerical reasoning; this is the assembly-level summary):
;
; 1. sat_type 1 (Radiant, 4x weighted sine sum) and sat_type 2 (Luster/Dark
;    Essence, x*a/exp(|(x*b)^5|)) are fit here as degree-15 ODD polynomials
;    over the SAME [-1, Q123_MAX] domain sat_type 0 already clamps to (both
;    measured exactly odd; fit errors 2.72e-4 and 1.29e-3). All three
;    sat_types now share ONE data-driven 15-term evaluator
;    (gen_poly_block_v2) instead of sat_type 0's hardcoded-immediate one --
;    the clamp block itself is UNCHANGED (same bounds for every sat_type).
;
; 2. POLY_SHIFT raised from v1's 3 to 7 (uniform across all 3 sat_types --
;    sat_type 1's own fit needs shift>=7). Re-quantizing sat_type 0's own
;    shipped coefficients at shift 7 instead of 3 adds at most 1.05e-4 of
;    new error to that polynomial's own output -- measured, not assumed.
;
; 3. A3/P20/P24 are no longer identical across Types -- all three become
;    real per-Type precomputed constants (still resolved once per
;    control-tick, in the now-5-way TYPE branch below, not per sample).
;
; 4. THREE NEW BRANCH-FREE PER-SAMPLE QUANTITIES (phoenix_l/r gain new
;    instructions but ZERO new control-transfer instructions -- the
;    bsr-straight-line rule, point 9 below, is unaffected):
;      a. X3 blend: X3S_BY32 = X_TRIMMED_BY32 + G0*(X2S_SAFE-X_TRIMMED_BY32)
;         (G0 precomputed 0 or ~1 per Type -- v1 hardcoded X3=X2 since both
;         its Types had g0=1; Radiant/Luster/Dark Essence have g0=0).
;      b. X4_MULT: X4's own Phoenix_sat input is X2S_SAFE*X4_MULT (X4_MULT
;         precomputed to PROCESSING for Luster, ~1.0 -- Q123_MAX, same
;         "closest representable" trick AUTO_GAIN's off-state already uses
;         -- otherwise), asl #5 straight into the clamp, same discipline as
;         v1's own TRUE_X2 (never a boosted value in a plain register).
;      c. Y_SCALE_HALF/Y_SCALE_P24_X32_HALF replace v1's plain PROCESSING/
;         PROCESSING_P24_X32 in the final y_pre step: Y_SCALE folds
;         Luster's own `y *= 0.5` into ONE constant (Y_SCALE=PROCESSING*
;         (0.5 if Luster else 1)); the HALF suffix is a SEPARATE, always-
;         applied extra halving needed because Luster's own a3=1.0/p24*32=
;         3.75 combination would otherwise push the old PROCESSING_P24_X32
;         quantity to 1.875 -- not representable as a plain Q1.23 word (v1
;         never hit this because both its Types capped PROCESSING<=0.25).
;         The one-line knock-on effect: the final undo-shift on
;         (TERM_C-TERM_D) is `asr #4` here, not v1's `asr #5`.
;
; 5. A NEW mpy PATTERN, flagged rather than silently trusted: 4 of the 15
;    polynomial coefficient slots (degrees 5, 11, 13, 15) have a sign that
;    DIFFERS between sat_type 2 and sat_type 0/1 -- the sign can no longer
;    be resolved by choosing add-vs-subtract at code-generation time (one
;    shared instruction sequence serves every Type), so those 4 slots
;    store a genuinely SIGNED coefficient and the final accumulate is an
;    unconditional `add`. This is the first mpy site in this project where
;    NEITHER operand's sign is fixed at code-generation time (the
;    composite power's sign follows the audio signal; the coefficient's
;    sign now follows a runtime Type selection) -- every other mpy here and
;    in every prior module keeps one operand guaranteed non-negative, per
;    the established convention. Standard DSP `mpy` semantics are a plain
;    signed x signed fractional multiply, so there's no specific reason to
;    expect trouble, but this exact pattern has not been exercised by any
;    prior module and needs the same real-hardware confirmation as every
;    other design choice here -- see gen_phoenix_asm_blocks_v2.py's own
;    header for the full writeup.
;
; 6. Headroom shifts (X2_SHIFT=5, plain-Q1.23 for X4/X5/S, OUTPUT_TRIM_SHIFT
;    =1) are UNCHANGED from v1 -- re-verified across all 5 Types (not
;    assumed still valid) via sim_phoenix.py's own worst-case sweep: worst
;    |x2|=4.4985 and worst |y_final|=1.2076 both occur at EXISTING v1 Types
;    (Iridescent/Opal, Luminescent/Sapphire), not any of the 3 new ones.
;
; Every v1 design point not listed above (Input Trim /32 scale, Phoenix_
; sat's self-bounding output, the branchless double clamp, Output Trim's
; /32-then-asl-#6 undo, the general mpy operand-order convention, the
; bsr-straight-line rule) is UNCHANGED.
;
; 7. mpy operand-order convention (unchanged from v1, still followed for
;    every OTHER mpy site): whichever operand can be negative goes FIRST; a
;    guaranteed non-negative magnitude goes SECOND, sign applied via
;    add-vs-subtract where the sign is fixed at code-generation time.
;
; 8. Auto Gain's own quadratic is always computed and always multiplied
;    (AUTO_GAIN precomputed to ~1.0 when the toggle is off) -- unchanged
;    from v1, avoids a per-sample branch.
;
; 9. bsr-straight-line rule (TapeHead's own session): a bsr callee reached
;    from the sample loop may contain NO control-transfer instruction of
;    any kind. phoenix_l/phoenix_r remain single unbroken straight-line
;    blocks despite the new per-sample instructions in point 4 above --
;    every new quantity is computed via mpy/add/asl/asr only, no new
;    bra/bcc/bsr. poly6 keeps its own bsr (called only from proc:'s
;    precompute, outside the sample loop, now via a 5-way TYPE branch
;    instead of v1's 2-way -- see point 3).
;
; r7 memory map:
;   $00       L S              (persistent, one-pole state, plain Q1.23)
;   $01       L PREV_X_BY32    (persistent, true/32)
;   $02       R S              (persistent)
;   $03       R PREV_X_BY32    (persistent)
;   $04       HPF_K            (per-block, Brightness x Type select, >=0)
;   $05       LPF_K            (per-block, >=0)
;   $06       LPF_K_COMP       (per-block, =1-LPF_K, >=0)
;   $07       F1               (per-block, Type select, >=0)
;   $08       AUTO_GAIN_A1_MAG (per-block, Type select, >=0, transient)
;   $09       AUTO_GAIN_A2     (per-block, Type select, >=0, transient)
;   $0a       PROCESSING       (per-block, = Process_frac*A3, real mpy now)
;   $0b       PP20             (per-block, = PROCESSING*P20; also reused as
;             a transient P20 staging slot inside the TYPE branch itself)
;   $0c       Y_SCALE_P24_X32_HALF (per-block, was PROCESSING_P24_X32 in v1)
;   $0d       AUTO_GAIN        (per-block, quadratic or ~1.0 if toggle off)
;   $0e       INPUT_TRIM_K_BY32  (per-block, poly6 fit, >=0)
;   $0f       OUTPUT_TRIM_K_BY2  (per-block, poly6 fit, >=0)
;   $10-$14   poly6 staging: STAGE_X1..X5 (t^1..t^5)
;   $15-$1a   poly6 staging: STAGE_C0..C5 (p0..p5) -- $1a doubles as A3
;             staging within the TYPE branch (consumed immediately after)
;   $1c       G0               (per-block, Type select, 0 or ~1) -- NEW
;   $1d       Y_SCALE_HALF     (per-block, replaces v1's plain PROCESSING
;             in the final y_pre step) -- NEW
;   $1e       X4_MULT          (per-block, PROCESSING if Luster else ~1;
;             also doubles as IS_LUSTER staging within the TYPE branch) -- NEW
;   $1f-$2d   POLY_COEF[deg 1..15] (per-block, this Type's own 15-term
;             coefficient table -- magnitude for 11 fixed-sign degrees,
;             SIGNED for degrees 5/11/13/15, see point 5 above) -- NEW
;   $2e-$41   L channel per-sample scratch (20 words, same shape as v1's
;             $1c-$2f: X_TRIMMED_BY32, X1S, X2S_SAFE, XC/P2/P4/P6/P8/P10/
;             P12/P14, X4, X4_PP20, X5, TERM_A, TERM_B, S_NEW, TERM_C,
;             TERM_D, Y_BY32)
;   $42-$55   R channel per-sample scratch (mirror of $2e-$41)
; Total: $00-$55 (86 words) -- 18 more than v1's 68 (the new shared G0/
; Y_SCALE_HALF/X4_MULT/15-coefficient-table area; channel scratch itself is
; unchanged in size).
;
; Constants are computed programmatically by gen_phoenix_asm_v2.py from
; sim_phoenix.py / sim_phoenix_fixed_v2.py directly -- not hand-typed.
; ---------------------------------------------------------------------------

; ---------------------------------------------------------------------------
init:
        move    #0,a
        move    a,x:(r7+$0)
        move    a,x:(r7+$1)
        move    a,x:(r7+$2)
        move    a,x:(r7+$3)
        rts

; ---------------------------------------------------------------------------
proc:
; ---- precompute (once per call): TYPE x BRIGHTNESS -> HPF_K/LPF_K/
; LPF_K_COMP/F1/AUTO_GAIN_A1_MAG/AUTO_GAIN_A2/A3/P20/G0/IS_LUSTER/15 poly
; coefficients; PROCESS -> PROCESSING/PP20/Y_SCALE_HALF/
; Y_SCALE_P24_X32_HALF/X4_MULT; AUTO GAIN toggle -> AUTO_GAIN; INPUT TRIM/
; OUTPUT TRIM -> their poly6 fits. None of this runs in the per-sample
; loop. -------------------------------------------------------------------

        move    x:(r6+$4),a              ; TYPE raw (0=LUMINESCENT,
                                          ; 1=IRIDESCENT, 2=RADIANT,
                                          ; 3=LUSTER, 4=DARK ESSENCE)
        tst     a
        beq     type0
        move    x:(r6+$4),a
        move    #>$1,x0
        sub     x0,a
        tst     a
        beq     type1
        move    x:(r6+$4),a
        move    #>$2,x0
        sub     x0,a
        tst     a
        beq     type2
        move    x:(r6+$4),a
        move    #>$3,x0
        sub     x0,a
        tst     a
        beq     type3
; ---- TYPE 4 (DARK ESSENCE), falls through from the type3 test ----
        move    #>$600000,y0             ; F1
        move    y0,x:(r7+$7)
        move    #>$516872,y0             ; AUTO_GAIN_A1_MAG
        move    y0,x:(r7+$8)
        move    #>$15C28F,y0             ; AUTO_GAIN_A2
        move    y0,x:(r7+$9)
        move    #>$300000,y0             ; A3
        move    y0,x:(r7+$1a)            ; A3 staged (T2_SCRATCH area,
                                          ; consumed immediately after
                                          ; mode_done, see PROCESS section)
        move    #>$480000,y0             ; P20
        move    y0,x:(r7+$b)             ; P20 (temporarily -- PP20 itself
                                          ; overwrites this slot below)
        move    #>$019999,y0             ; P24 (NOT p24*32 -- see
                                          ; TYPE_HEX's own note: p24*32 can
                                          ; exceed 1.0, p24 itself never does)
        move    y0,x:(r7+$19)            ; P24 staged (STAGE_C4 area,
                                          ; consumed by the Y_SCALE_P24_X32_
                                          ; HALF step below, well before
                                          ; INPUT_TRIM's own poly6 call reuses
                                          ; this cell)
        move    #>$000000,y0             ; G0 (0 or ~1)
        move    y0,x:(r7+$1C)
        move    #>$000000,y0             ; IS_LUSTER (0 or ~1)
        move    y0,x:(r7+$1E)            ; staged here temporarily,
                                          ; PROCESS section below turns
                                          ; this into the real X4_MULT
; ---- this Type's 15 poly coefficients (sat_type=2) ----
        move    #>$020DD7,y0             ; deg1 coeff (magnitude)
        move    y0,x:(r7+$1F)
        move    #>$000000,y0             ; deg2 coeff (magnitude)
        move    y0,x:(r7+$20)
        move    #>$00118E,y0             ; deg3 coeff (magnitude)
        move    y0,x:(r7+$21)
        move    #>$000000,y0             ; deg4 coeff (magnitude)
        move    y0,x:(r7+$22)
        move    #>$FF492D,y0             ; deg5 coeff (signed)
        move    y0,x:(r7+$23)
        move    #>$000000,y0             ; deg6 coeff (magnitude)
        move    y0,x:(r7+$24)
        move    #>$140D0D,y0             ; deg7 coeff (magnitude)
        move    y0,x:(r7+$25)
        move    #>$000000,y0             ; deg8 coeff (magnitude)
        move    y0,x:(r7+$26)
        move    #>$193C9B,y0             ; deg9 coeff (magnitude)
        move    y0,x:(r7+$27)
        move    #>$000000,y0             ; deg10 coeff (magnitude)
        move    y0,x:(r7+$28)
        move    #>$0E2CEE,y0             ; deg11 coeff (signed)
        move    y0,x:(r7+$29)
        move    #>$000000,y0             ; deg12 coeff (magnitude)
        move    y0,x:(r7+$2A)
        move    #>$DE141D,y0             ; deg13 coeff (signed)
        move    y0,x:(r7+$2B)
        move    #>$000000,y0             ; deg14 coeff (magnitude)
        move    y0,x:(r7+$2C)
        move    #>$0D5033,y0             ; deg15 coeff (signed)
        move    y0,x:(r7+$2D)
; ---- BRIGHTNESS 3-way select ----
        move    x:(r6+$3),a              ; BRIGHTNESS raw
        tst     a
        beq     t4_opal
        move    #>$1,x0
        sub     x0,a
        beq     t4_gold
; BRIGHTNESS==2 (SAPPHIRE)
        move    #>$300000,y0
        move    y0,x:(r7+$4)             ; HPF_K
        move    #>$480000,y0
        move    y0,x:(r7+$5)             ; LPF_K
        move    #>$380000,y0
        move    y0,x:(r7+$6)             ; LPF_K_COMP
        bra     mode_done
t4_opal:
        move    #>$600000,y0
        move    y0,x:(r7+$4)
        move    #>$100000,y0
        move    y0,x:(r7+$5)
        move    #>$700000,y0
        move    y0,x:(r7+$6)
        bra     mode_done
t4_gold:
        move    #>$3A6801,y0
        move    y0,x:(r7+$4)
        move    #>$300000,y0
        move    y0,x:(r7+$5)
        move    #>$500000,y0
        move    y0,x:(r7+$6)
        bra     mode_done

type3:
; ---- TYPE 3 (LUSTER) ----
        move    #>$580000,y0             ; F1
        move    y0,x:(r7+$7)
        move    #>$5B22D0,y0             ; AUTO_GAIN_A1_MAG
        move    y0,x:(r7+$8)
        move    #>$160418,y0             ; AUTO_GAIN_A2
        move    y0,x:(r7+$9)
        move    #>$7FFFFF,y0             ; A3
        move    y0,x:(r7+$1a)            ; A3 staged (T2_SCRATCH area,
                                          ; consumed immediately after
                                          ; mode_done, see PROCESS section)
        move    #>$23000C,y0             ; P20
        move    y0,x:(r7+$b)             ; P20 (temporarily -- PP20 itself
                                          ; overwrites this slot below)
        move    #>$0F0000,y0             ; P24 (NOT p24*32 -- see
                                          ; TYPE_HEX's own note: p24*32 can
                                          ; exceed 1.0, p24 itself never does)
        move    y0,x:(r7+$19)            ; P24 staged (STAGE_C4 area,
                                          ; consumed by the Y_SCALE_P24_X32_
                                          ; HALF step below, well before
                                          ; INPUT_TRIM's own poly6 call reuses
                                          ; this cell)
        move    #>$000000,y0             ; G0 (0 or ~1)
        move    y0,x:(r7+$1C)
        move    #>$7FFFFF,y0             ; IS_LUSTER (0 or ~1)
        move    y0,x:(r7+$1E)            ; staged here temporarily,
                                          ; PROCESS section below turns
                                          ; this into the real X4_MULT
; ---- this Type's 15 poly coefficients (sat_type=2) ----
        move    #>$020DD7,y0             ; deg1 coeff (magnitude)
        move    y0,x:(r7+$1F)
        move    #>$000000,y0             ; deg2 coeff (magnitude)
        move    y0,x:(r7+$20)
        move    #>$00118E,y0             ; deg3 coeff (magnitude)
        move    y0,x:(r7+$21)
        move    #>$000000,y0             ; deg4 coeff (magnitude)
        move    y0,x:(r7+$22)
        move    #>$FF492D,y0             ; deg5 coeff (signed)
        move    y0,x:(r7+$23)
        move    #>$000000,y0             ; deg6 coeff (magnitude)
        move    y0,x:(r7+$24)
        move    #>$140D0D,y0             ; deg7 coeff (magnitude)
        move    y0,x:(r7+$25)
        move    #>$000000,y0             ; deg8 coeff (magnitude)
        move    y0,x:(r7+$26)
        move    #>$193C9B,y0             ; deg9 coeff (magnitude)
        move    y0,x:(r7+$27)
        move    #>$000000,y0             ; deg10 coeff (magnitude)
        move    y0,x:(r7+$28)
        move    #>$0E2CEE,y0             ; deg11 coeff (signed)
        move    y0,x:(r7+$29)
        move    #>$000000,y0             ; deg12 coeff (magnitude)
        move    y0,x:(r7+$2A)
        move    #>$DE141D,y0             ; deg13 coeff (signed)
        move    y0,x:(r7+$2B)
        move    #>$000000,y0             ; deg14 coeff (magnitude)
        move    y0,x:(r7+$2C)
        move    #>$0D5033,y0             ; deg15 coeff (signed)
        move    y0,x:(r7+$2D)
; ---- BRIGHTNESS 3-way select ----
        move    x:(r6+$3),a              ; BRIGHTNESS raw
        tst     a
        beq     t3_opal
        move    #>$1,x0
        sub     x0,a
        beq     t3_gold
; BRIGHTNESS==2 (SAPPHIRE)
        move    #>$300000,y0
        move    y0,x:(r7+$4)             ; HPF_K
        move    #>$480000,y0
        move    y0,x:(r7+$5)             ; LPF_K
        move    #>$380000,y0
        move    y0,x:(r7+$6)             ; LPF_K_COMP
        bra     mode_done
t3_opal:
        move    #>$600000,y0
        move    y0,x:(r7+$4)
        move    #>$100000,y0
        move    y0,x:(r7+$5)
        move    #>$700000,y0
        move    y0,x:(r7+$6)
        bra     mode_done
t3_gold:
        move    #>$3A6801,y0
        move    y0,x:(r7+$4)
        move    #>$300000,y0
        move    y0,x:(r7+$5)
        move    #>$500000,y0
        move    y0,x:(r7+$6)
        bra     mode_done

type2:
; ---- TYPE 2 (RADIANT) ----
        move    #>$600000,y0             ; F1
        move    y0,x:(r7+$7)
        move    #>$3872B0,y0             ; AUTO_GAIN_A1_MAG
        move    y0,x:(r7+$8)
        move    #>$0D2F1A,y0             ; AUTO_GAIN_A2
        move    y0,x:(r7+$9)
        move    #>$300000,y0             ; A3
        move    y0,x:(r7+$1a)            ; A3 staged (T2_SCRATCH area,
                                          ; consumed immediately after
                                          ; mode_done, see PROCESS section)
        move    #>$180000,y0             ; P20
        move    y0,x:(r7+$b)             ; P20 (temporarily -- PP20 itself
                                          ; overwrites this slot below)
        move    #>$019999,y0             ; P24 (NOT p24*32 -- see
                                          ; TYPE_HEX's own note: p24*32 can
                                          ; exceed 1.0, p24 itself never does)
        move    y0,x:(r7+$19)            ; P24 staged (STAGE_C4 area,
                                          ; consumed by the Y_SCALE_P24_X32_
                                          ; HALF step below, well before
                                          ; INPUT_TRIM's own poly6 call reuses
                                          ; this cell)
        move    #>$000000,y0             ; G0 (0 or ~1)
        move    y0,x:(r7+$1C)
        move    #>$000000,y0             ; IS_LUSTER (0 or ~1)
        move    y0,x:(r7+$1E)            ; staged here temporarily,
                                          ; PROCESS section below turns
                                          ; this into the real X4_MULT
; ---- this Type's 15 poly coefficients (sat_type=1) ----
        move    #>$017DFE,y0             ; deg1 coeff (magnitude)
        move    y0,x:(r7+$1F)
        move    #>$000000,y0             ; deg2 coeff (magnitude)
        move    y0,x:(r7+$20)
        move    #>$002BFD,y0             ; deg3 coeff (magnitude)
        move    y0,x:(r7+$21)
        move    #>$000000,y0             ; deg4 coeff (magnitude)
        move    y0,x:(r7+$22)
        move    #>$024738,y0             ; deg5 coeff (signed)
        move    y0,x:(r7+$23)
        move    #>$000000,y0             ; deg6 coeff (magnitude)
        move    y0,x:(r7+$24)
        move    #>$226367,y0             ; deg7 coeff (magnitude)
        move    y0,x:(r7+$25)
        move    #>$000000,y0             ; deg8 coeff (magnitude)
        move    y0,x:(r7+$26)
        move    #>$4FC6A9,y0             ; deg9 coeff (magnitude)
        move    y0,x:(r7+$27)
        move    #>$000000,y0             ; deg10 coeff (magnitude)
        move    y0,x:(r7+$28)
        move    #>$AD52BF,y0             ; deg11 coeff (signed)
        move    y0,x:(r7+$29)
        move    #>$000000,y0             ; deg12 coeff (magnitude)
        move    y0,x:(r7+$2A)
        move    #>$2AC9F5,y0             ; deg13 coeff (signed)
        move    y0,x:(r7+$2B)
        move    #>$000000,y0             ; deg14 coeff (magnitude)
        move    y0,x:(r7+$2C)
        move    #>$F6E6A5,y0             ; deg15 coeff (signed)
        move    y0,x:(r7+$2D)
; ---- BRIGHTNESS 3-way select ----
        move    x:(r6+$3),a              ; BRIGHTNESS raw
        tst     a
        beq     t2_opal
        move    #>$1,x0
        sub     x0,a
        beq     t2_gold
; BRIGHTNESS==2 (SAPPHIRE)
        move    #>$300000,y0
        move    y0,x:(r7+$4)             ; HPF_K
        move    #>$400000,y0
        move    y0,x:(r7+$5)             ; LPF_K
        move    #>$400000,y0
        move    y0,x:(r7+$6)             ; LPF_K_COMP
        bra     mode_done
t2_opal:
        move    #>$600000,y0
        move    y0,x:(r7+$4)
        move    #>$100000,y0
        move    y0,x:(r7+$5)
        move    #>$700000,y0
        move    y0,x:(r7+$6)
        bra     mode_done
t2_gold:
        move    #>$3A6801,y0
        move    y0,x:(r7+$4)
        move    #>$300000,y0
        move    y0,x:(r7+$5)
        move    #>$500000,y0
        move    y0,x:(r7+$6)
        bra     mode_done

type1:
; ---- TYPE 1 (IRIDESCENT) ----
        move    #>$700000,y0             ; F1
        move    y0,x:(r7+$7)
        move    #>$324DD2,y0             ; AUTO_GAIN_A1_MAG
        move    y0,x:(r7+$8)
        move    #>$0A7EF9,y0             ; AUTO_GAIN_A2
        move    y0,x:(r7+$9)
        move    #>$200000,y0             ; A3
        move    y0,x:(r7+$1a)            ; A3 staged (T2_SCRATCH area,
                                          ; consumed immediately after
                                          ; mode_done, see PROCESS section)
        move    #>$280000,y0             ; P20
        move    y0,x:(r7+$b)             ; P20 (temporarily -- PP20 itself
                                          ; overwrites this slot below)
        move    #>$080000,y0             ; P24 (NOT p24*32 -- see
                                          ; TYPE_HEX's own note: p24*32 can
                                          ; exceed 1.0, p24 itself never does)
        move    y0,x:(r7+$19)            ; P24 staged (STAGE_C4 area,
                                          ; consumed by the Y_SCALE_P24_X32_
                                          ; HALF step below, well before
                                          ; INPUT_TRIM's own poly6 call reuses
                                          ; this cell)
        move    #>$7FFFFF,y0             ; G0 (0 or ~1)
        move    y0,x:(r7+$1C)
        move    #>$000000,y0             ; IS_LUSTER (0 or ~1)
        move    y0,x:(r7+$1E)            ; staged here temporarily,
                                          ; PROCESS section below turns
                                          ; this into the real X4_MULT
; ---- this Type's 15 poly coefficients (sat_type=0) ----
        move    #>$02D3DB,y0             ; deg1 coeff (magnitude)
        move    y0,x:(r7+$1F)
        move    #>$000019,y0             ; deg2 coeff (magnitude)
        move    y0,x:(r7+$20)
        move    #>$042C15,y0             ; deg3 coeff (magnitude)
        move    y0,x:(r7+$21)
        move    #>$000007,y0             ; deg4 coeff (magnitude)
        move    y0,x:(r7+$22)
        move    #>$008601,y0             ; deg5 coeff (signed)
        move    y0,x:(r7+$23)
        move    #>$000012,y0             ; deg6 coeff (magnitude)
        move    y0,x:(r7+$24)
        move    #>$006C6D,y0             ; deg7 coeff (magnitude)
        move    y0,x:(r7+$25)
        move    #>$00005E,y0             ; deg8 coeff (magnitude)
        move    y0,x:(r7+$26)
        move    #>$03397E,y0             ; deg9 coeff (magnitude)
        move    y0,x:(r7+$27)
        move    #>$0000B2,y0             ; deg10 coeff (magnitude)
        move    y0,x:(r7+$28)
        move    #>$FA8131,y0             ; deg11 coeff (signed)
        move    y0,x:(r7+$29)
        move    #>$0000BA,y0             ; deg12 coeff (magnitude)
        move    y0,x:(r7+$2A)
        move    #>$057324,y0             ; deg13 coeff (signed)
        move    y0,x:(r7+$2B)
        move    #>$000055,y0             ; deg14 coeff (magnitude)
        move    y0,x:(r7+$2C)
        move    #>$FD95FE,y0             ; deg15 coeff (signed)
        move    y0,x:(r7+$2D)
; ---- BRIGHTNESS 3-way select ----
        move    x:(r6+$3),a              ; BRIGHTNESS raw
        tst     a
        beq     t1_opal
        move    #>$1,x0
        sub     x0,a
        beq     t1_gold
; BRIGHTNESS==2 (SAPPHIRE)
        move    #>$280000,y0
        move    y0,x:(r7+$4)             ; HPF_K
        move    #>$400000,y0
        move    y0,x:(r7+$5)             ; LPF_K
        move    #>$400000,y0
        move    y0,x:(r7+$6)             ; LPF_K_COMP
        bra     mode_done
t1_opal:
        move    #>$500000,y0
        move    y0,x:(r7+$4)
        move    #>$180000,y0
        move    y0,x:(r7+$5)
        move    #>$680000,y0
        move    y0,x:(r7+$6)
        bra     mode_done
t1_gold:
        move    #>$300000,y0
        move    y0,x:(r7+$4)
        move    #>$280000,y0
        move    y0,x:(r7+$5)
        move    #>$580000,y0
        move    y0,x:(r7+$6)
        bra     mode_done

type0:
; ---- TYPE 0 (LUMINESCENT) ----
        move    #>$600000,y0             ; F1
        move    y0,x:(r7+$7)
        move    #>$353F7C,y0             ; AUTO_GAIN_A1_MAG
        move    y0,x:(r7+$8)
        move    #>$0BC6A7,y0             ; AUTO_GAIN_A2
        move    y0,x:(r7+$9)
        move    #>$200000,y0             ; A3
        move    y0,x:(r7+$1a)            ; A3 staged (T2_SCRATCH area,
                                          ; consumed immediately after
                                          ; mode_done, see PROCESS section)
        move    #>$280000,y0             ; P20
        move    y0,x:(r7+$b)             ; P20 (temporarily -- PP20 itself
                                          ; overwrites this slot below)
        move    #>$080000,y0             ; P24 (NOT p24*32 -- see
                                          ; TYPE_HEX's own note: p24*32 can
                                          ; exceed 1.0, p24 itself never does)
        move    y0,x:(r7+$19)            ; P24 staged (STAGE_C4 area,
                                          ; consumed by the Y_SCALE_P24_X32_
                                          ; HALF step below, well before
                                          ; INPUT_TRIM's own poly6 call reuses
                                          ; this cell)
        move    #>$7FFFFF,y0             ; G0 (0 or ~1)
        move    y0,x:(r7+$1C)
        move    #>$000000,y0             ; IS_LUSTER (0 or ~1)
        move    y0,x:(r7+$1E)            ; staged here temporarily,
                                          ; PROCESS section below turns
                                          ; this into the real X4_MULT
; ---- this Type's 15 poly coefficients (sat_type=0) ----
        move    #>$02D3DB,y0             ; deg1 coeff (magnitude)
        move    y0,x:(r7+$1F)
        move    #>$000019,y0             ; deg2 coeff (magnitude)
        move    y0,x:(r7+$20)
        move    #>$042C15,y0             ; deg3 coeff (magnitude)
        move    y0,x:(r7+$21)
        move    #>$000007,y0             ; deg4 coeff (magnitude)
        move    y0,x:(r7+$22)
        move    #>$008601,y0             ; deg5 coeff (signed)
        move    y0,x:(r7+$23)
        move    #>$000012,y0             ; deg6 coeff (magnitude)
        move    y0,x:(r7+$24)
        move    #>$006C6D,y0             ; deg7 coeff (magnitude)
        move    y0,x:(r7+$25)
        move    #>$00005E,y0             ; deg8 coeff (magnitude)
        move    y0,x:(r7+$26)
        move    #>$03397E,y0             ; deg9 coeff (magnitude)
        move    y0,x:(r7+$27)
        move    #>$0000B2,y0             ; deg10 coeff (magnitude)
        move    y0,x:(r7+$28)
        move    #>$FA8131,y0             ; deg11 coeff (signed)
        move    y0,x:(r7+$29)
        move    #>$0000BA,y0             ; deg12 coeff (magnitude)
        move    y0,x:(r7+$2A)
        move    #>$057324,y0             ; deg13 coeff (signed)
        move    y0,x:(r7+$2B)
        move    #>$000055,y0             ; deg14 coeff (magnitude)
        move    y0,x:(r7+$2C)
        move    #>$FD95FE,y0             ; deg15 coeff (signed)
        move    y0,x:(r7+$2D)
; ---- BRIGHTNESS 3-way select ----
        move    x:(r6+$3),a              ; BRIGHTNESS raw
        tst     a
        beq     t0_opal
        move    #>$1,x0
        sub     x0,a
        beq     t0_gold
; BRIGHTNESS==2 (SAPPHIRE)
        move    #>$180000,y0
        move    y0,x:(r7+$4)             ; HPF_K
        move    #>$300000,y0
        move    y0,x:(r7+$5)             ; LPF_K
        move    #>$500000,y0
        move    y0,x:(r7+$6)             ; LPF_K_COMP
        bra     mode_done
t0_opal:
        move    #>$500000,y0
        move    y0,x:(r7+$4)
        move    #>$180000,y0
        move    y0,x:(r7+$5)
        move    #>$680000,y0
        move    y0,x:(r7+$6)
        bra     mode_done
t0_gold:
        move    #>$380000,y0
        move    y0,x:(r7+$4)
        move    #>$280000,y0
        move    y0,x:(r7+$5)
        move    #>$580000,y0
        move    y0,x:(r7+$6)
        bra     mode_done
mode_done:

; ---- PROCESS: raw 0..127 at x:(r6+$1), t = raw/128. PROCESSING = t*A3
; (real mpy now -- A3 varies per Type, staged at $1a by the TYPE branch
; above) ----
        move    x:(r6+$1),y1             ; t (>=0, first... but see below:
                                          ; A3 is also >=0, so either order
                                          ; is safe here; kept t-first for
                                          ; consistency with every other
                                          ; "signal-like value first" site)
        move    x:(r7+$1a),y0            ; A3 (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$a)              ; PROCESSING
        move    a,y1                     ; PROCESSING (>=0, first)
        move    x:(r7+$b),y0             ; P20 (>=0, second -- staged by
                                          ; the TYPE branch above)
        mpy     y1,y0,a
        move    a,x:(r7+$b)              ; PP20 (overwrites the P20 staging)

; ---- Y_SCALE_HALF = PROCESSING * (0.25 if Luster else 0.5). IS_LUSTER
; (staged at $1e by the TYPE branch) selects via a REAL branch -- fine
; here, precompute is outside the sample loop (point 9 above); no
; per-sample cost. ----
        move    x:(r7+$1e),a             ; IS_LUSTER (0 or ~1)
        tst     a
        beq     lus_off                  ; NOTE: kept SHORT (<=7 chars) and
                                          ; free of "not" as a substring.
                                          ; A real `make check` failure hit
                                          ; here: a label originally named
                                          ; x4mult_not_luster (18 chars)
                                          ; produced "InvalidInstruction --
                                          ; beq x4mult_-$12" from the real
                                          ; dsp_asm -- garbled exactly at
                                          ; the "not" substring, and/or its
                                          ; length (v1's own longest real,
                                          ; hardware-verified labels top
                                          ; out at 9 chars: mode_done,
                                          ; phoenix_l, phoenix_r). Root
                                          ; cause not conclusively isolated
                                          ; from this session alone (no
                                          ; access to dsp_asm's own source),
                                          ; so every label here is kept
                                          ; short AND "not"-free as cheap
                                          ; insurance against both possible
                                          ; causes rather than betting on
                                          ; either explanation alone.
        move    x:(r7+$a),y1             ; PROCESSING (>=0, first)
        move    #>$200000,y0             ; 0.25 (exact, >=0, second --
                                          ; computed via q123_hex, not hand-
                                          ; typed: an earlier draft hand-typed
                                          ; $400000/$800000 here, which are
                                          ; actually 0.5 and -1.0 (!) in
                                          ; Q1.23, not 0.25/0.5 -- caught by
                                          ; verify_phoenix_asm_v2.py finding a
                                          ; negative Y_SCALE_HALF)
        mpy     y1,y0,a
        bra     ysc_don
lus_off:
        move    x:(r7+$a),y1             ; PROCESSING (>=0, first)
        move    #>$400000,y0             ; 0.5 (exact, >=0, second)
        mpy     y1,y0,a
ysc_don:
        move    a,x:(r7+$1d)             ; Y_SCALE_HALF

; ---- Y_SCALE_P24_X32_HALF = (Y_SCALE_HALF * P24) * 32. Stored as the
; SMALL P24 constant (per-Type, staged at $19 by the TYPE branch above --
; NOT P24*32 itself, which exceeds 1.0/is unrepresentable for several
; Types, e.g. type0's 0.0625*32=2.0), then a plain asl #5 does the *32 --
; the product Y_SCALE_HALF*P24 is always small enough that the *32'd
; result stays under 1.0 for every Type (worst case 0.9375 at Luster,
; 100% Process -- see sim_phoenix_fixed_v2.py's own header point 4c). ----
        move    x:(r7+$1d),y1            ; Y_SCALE_HALF (>=0, first)
        move    x:(r7+$19),y0            ; P24 (>=0, second)
        mpy     y1,y0,a                   ; a = Y_SCALE_HALF*P24 (small)
        asl     #$5,a,a                   ; a = Y_SCALE_P24_X32_HALF (*32)
        move    a,x:(r7+$c)              ; Y_SCALE_P24_X32_HALF

; ---- X4_MULT: PROCESSING if Luster, ~1.0 (Q123_MAX) otherwise --
; IS_LUSTER already tested above (lus_off:/ysc_don: path), reuse the same
; test rather than re-reading $1e a second time would need a second branch
; anyway since `a` was clobbered -- re-test directly ----
        move    x:(r7+$1e),a             ; IS_LUSTER (0 or ~1)
        tst     a
        beq     x4m_off                  ; see lus_off's own note above --
                                          ; kept short and "not"-free
        move    x:(r7+$a),a              ; PROCESSING
        bra     x4m_don
x4m_off:
        move    #>$7FFFFF,a              ; ~1.0 (Q123_MAX)
x4m_don:
        move    a,x:(r7+$1e)             ; X4_MULT (overwrites IS_LUSTER
                                          ; staging -- no longer needed)

; ---- AUTO GAIN toggle, raw 0/1 at x:(r6+$5) ----
        move    x:(r6+$5),a
        tst     a
        beq     ag_off
        move    x:(r6+$1),x0             ; t
        move    x0,x1
        mpy     x0,x1,a                  ; t^2 (t>=0, safe)
        move    a,x:(r7+$1b)             ; T2_SCRATCH (reused transiently;
                                          ; TRUE_X3's own per-sample stash
                                          ; at this SAME offset runs only
                                          ; inside phoenix_l/r, never
                                          ; overlapping precompute's use)
        move    x0,y1                    ; t (first)
        move    x:(r7+$8),y0             ; AUTO_GAIN_A1_MAG (>=0, second)
        mpy     y1,y0,b                  ; b = t*AG1_MAG
        move    #>$7FFFFF,a              ; a = ~1.0
        sub     b,a                      ; a = ~1 - t*AG1_MAG
        move    x:(r7+$1b),y1            ; t^2 (first)
        move    x:(r7+$9),y0             ; AUTO_GAIN_A2 (>=0, second)
        mpy     y1,y0,b                  ; b = t^2*AG2
        add     b,a                      ; a = AUTO_GAIN
        bra     ag_done
ag_off:
        move    #>$7FFFFF,a              ; AUTO_GAIN = ~1
ag_done:
        move    a,x:(r7+$d)              ; AUTO_GAIN

; ---- INPUT TRIM: raw 0..127 at x:(r6+$0) ----
        move    x:(r6+$0),x0
        move    x0,x:(r7+$10)            ; STAGE_X1 = t
        move    x0,x1
        mpy     x0,x1,a                  ; t^2 (t>=0, safe)
        move    a,x:(r7+$11)
        move    a,y1
        mpy     x0,y1,a                  ; t^3
        move    a,x:(r7+$12)
        move    a,y1
        mpy     x0,y1,a                  ; t^4
        move    a,x:(r7+$13)
        move    a,y1
        mpy     x0,y1,a                  ; t^5
        move    a,x:(r7+$14)

        move    #>$0143A1,a
        move    a,x:(r7+$15)            ; STAGE_C0 (p0)
        move    #>$02F1E2,a
        move    a,x:(r7+$16)            ; p1
        move    #>$030859,a
        move    a,x:(r7+$17)            ; p2
        move    #>$03CE89,a
        move    a,x:(r7+$18)            ; p3
        move    #>$FF5993,a
        move    a,x:(r7+$19)            ; p4 (may be negative --
                                          ; see poly6's own header)
        move    #>$023FE3,a
        move    a,x:(r7+$1A)            ; p5
        bsr     poly6
        move    a,x:(r7+$E)            ; INPUT_TRIM_K_BY32 -- NO undo-shift

; ---- OUTPUT TRIM: raw 0..127 at x:(r6+$2) ----
        move    x:(r6+$2),x0
        move    x0,x:(r7+$10)            ; STAGE_X1 = t
        move    x0,x1
        mpy     x0,x1,a                  ; t^2 (t>=0, safe)
        move    a,x:(r7+$11)
        move    a,y1
        mpy     x0,y1,a                  ; t^3
        move    a,x:(r7+$12)
        move    a,y1
        mpy     x0,y1,a                  ; t^4
        move    a,x:(r7+$13)
        move    a,y1
        mpy     x0,y1,a                  ; t^5
        move    a,x:(r7+$14)

        move    #>$20134F,a
        move    a,x:(r7+$15)            ; STAGE_C0 (p0)
        move    #>$2C56D3,a
        move    a,x:(r7+$16)            ; p1
        move    #>$1E5D35,a
        move    a,x:(r7+$17)            ; p2
        move    #>$0F11AA,a
        move    a,x:(r7+$18)            ; p3
        move    #>$032107,a
        move    a,x:(r7+$19)            ; p4 (may be negative --
                                          ; see poly6's own header)
        move    #>$02B81E,a
        move    a,x:(r7+$1A)            ; p5
        bsr     poly6
        move    a,x:(r7+$F)            ; OUTPUT_TRIM_K_BY2 -- NO undo-shift

; ---- sample loop -----------------------------------------------------------
        move    #>$ffffff,m0
        move    #>$1,n0
        do      n7,>phxend

        move    x:(r0),a
        bsr     phoenix_l
        move    a,x:(r0)

        move    x:(r0+n0),a
        bsr     phoenix_r
        move    a,x:(r0+n0)

        move    #>$2,n0
        move    (r0)+n0
        move    #>$1,n0
phxend:
        rts

; ---------------------------------------------------------------------------
; phoenix_l / phoenix_r: process one channel end to end, fully inlined --
; zero bsr/bra/bcc of any kind, one `rts` each (point 9 above).
; ---------------------------------------------------------------------------
phoenix_l:
; ---- Input Trim, straight into /32 scale (v1, unchanged) ----
        move    a,y1                     ; raw x (signed, first)
        move    x:(r7+$e),y0             ; INPUT_TRIM_K_BY32 (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$2E)            ; X_TRIMMED_BY32

; ---- X1S/X2S_SAFE, /32 scale (v1, unchanged) ----
        move    x:(r7+$2E),y1        ; X_TRIMMED_BY32 (signed, first)
        move    x:(r7+$4),y0             ; HPF_K (>=0, second)
        mpy     y1,y0,a
        move    x:(r7+$2E),b
        add     b,a                       ; + X_TRIMMED_BY32
        move    x:(r7+$1),b        ; PREV_X_BY32 (old)
        sub     b,a                       ; a = X1S
        move    a,x:(r7+$2F)            ; X1S

        move    x:(r7+$2F),y1            ; X1S (signed, first)
        move    x:(r7+$7),y0             ; F1 (>=0, second)
        mpy     y1,y0,a
        move    x:(r7+$2F),b
        add     b,a                       ; a = X2S (/32 scale)
        move    a,x:(r7+$30)            ; X2S_SAFE (/32 scale)

; ---- X4 input: X2S_SAFE*X4_MULT at /32 scale (X4_MULT is
; PROCESSING for Luster, ~1.0 otherwise -- sim_phoenix_fixed_v2
; header pt 5b), THEN asl #5 straight into the clamp -- never a
; boosted value in a plain register (same discipline as v1's
; TRUE_X2, see gen_phoenix_asm.py's own header point 2). ----
        move    x:(r7+$30),y1        ; X2S_SAFE (signed, first)
        move    x:(r7+$1E),y0            ; X4_MULT (>=0, second)
        mpy     y1,y0,a                   ; X4_INPUT_BY32
        asl     #$5,a,a                   ; a = X4_INPUT_TRUE (transient)
        move    a,b                       ; b = P (stash)
        move    #>$800000,x0            ; LO = -1.0 true, exact
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a                   ; a = max(P,LO) = M
        move    a,b
        move    #>$7FFFFF,x0            ; HI = Q123_MAX true, exact
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b
        asr     #$1,b,b                   ; b = min(M,HI), SECOND halving --
                                          ; see this module's header on why
                                          ; this differs from tapehead.asm's
                                          ; own apparent clamp sequence
        move    b,a                       ; a = clamped(P, -1, Q123_MAX)
        move    a,x:(r7+$31)            ; XC
; ---- base powers: P2=XC^2, P4=P2^2, P6=P4*P2, P8=P4^2 ----
; ---- (all even powers of a real number -- guaranteed >=0) ----
        move    x:(r7+$31),x0
        move    x0,x1
        mpy     x0,x1,a                   ; P2 = XC*XC (both same sign or
                                          ; zero -- >=0 either way, safe)
        move    a,x:(r7+$32)
        move    a,y0                     ; P2 (kept live in y0 -- mpy
                                          ; never modifies its own source
                                          ; registers, so y0 is still
                                          ; valid for the P6 step below)
        mpy     y0,y0,a                   ; P4 = P2*P2 (P2>=0, safe)
        move    a,x:(r7+$33)
        move    a,y1                     ; P4, freshly captured from `a`
                                          ; right after the store above --
                                          ; NOT the same as an earlier draft
                                          ; of this block, which reused y1
                                          ; still holding P2 (from before
                                          ; the P4 step) here instead,
                                          ; silently computing P2*P2 (=P4)
                                          ; a second time rather than
                                          ; P4*P2 -- a real stale-register
                                          ; bug caught by
                                          ; verify_phoenix_asm_v2.py (it
                                          ; corrupted P6 for every Type,
                                          ; degree-7's own composite power,
                                          ; AND P14=P8*P6 downstream --
                                          ; present in gen_phoenix_asm_
                                          ; blocks.py's v1 gen_poly_block()
                                          ; too, likely the real explanation
                                          ; for v1's own larger-than-
                                          ; expected 3.1e-2 measured error)
        mpy     y1,y0,a                   ; P6 = P4*P2 (both >=0, safe)
        move    a,x:(r7+$34)
        move    x:(r7+$33),x1
        mpy     x1,x1,a                   ; P8 = P4*P4 (P4>=0, safe)
        move    a,x:(r7+$35)

; ---- P10=P8*P2, P12=P8*P4, P14=P8*P6 (all >=0, safe) ----
        move    x:(r7+$35),x1
        move    x:(r7+$32),y0
        mpy     x1,y0,a                   ; P10 = P8*P2
        move    a,x:(r7+$36)
        move    x:(r7+$35),x1
        move    x:(r7+$33),y0
        mpy     x1,y0,a                   ; P12 = P8*P4
        move    a,x:(r7+$37)
        move    x:(r7+$35),x1
        move    x:(r7+$34),y0
        mpy     x1,y0,a                   ; P14 = P8*P6
        move    a,x:(r7+$38)

; ---- 15-term running sum, coefficients read from r7 (selected per
; Type at precompute), accumulated directly in `a` ----
; deg=1 (add, stored as magnitude)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$1F),y0        ; |coeff deg1| (>=0, second)
        mpy     y1,y0,b
        move    b,a                      ; seed running sum

; deg=2 (add, stored as magnitude)
        move    x:(r7+$20),y0        ; |coeff deg2| (>=0, first)
        move    x:(r7+$32),y1        ; P2 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=3 (sub, stored as magnitude)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$32),y0        ; P2 (>=0, second)
        mpy     y1,y0,b                   ; P2*XC = deg-3 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$21),y0        ; |coeff deg3| (>=0, second)
        mpy     y1,y0,b
        sub     b,a

; deg=4 (sub, stored as magnitude)
        move    x:(r7+$22),y0        ; |coeff deg4| (>=0, first)
        move    x:(r7+$33),y1        ; P4 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=5 (variable sign, stored signed)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$33),y0        ; P4 (>=0, second)
        mpy     y1,y0,b                   ; P4*XC = deg-5 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$23),y0        ; SIGNED coeff deg5 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=6 (add, stored as magnitude)
        move    x:(r7+$24),y0        ; |coeff deg6| (>=0, first)
        move    x:(r7+$34),y1        ; P6 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=7 (sub, stored as magnitude)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$34),y0        ; P6 (>=0, second)
        mpy     y1,y0,b                   ; P6*XC = deg-7 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$25),y0        ; |coeff deg7| (>=0, second)
        mpy     y1,y0,b
        sub     b,a

; deg=8 (sub, stored as magnitude)
        move    x:(r7+$26),y0        ; |coeff deg8| (>=0, first)
        move    x:(r7+$35),y1        ; P8 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=9 (add, stored as magnitude)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$35),y0        ; P8 (>=0, second)
        mpy     y1,y0,b                   ; P8*XC = deg-9 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$27),y0        ; |coeff deg9| (>=0, second)
        mpy     y1,y0,b
        add     b,a

; deg=10 (add, stored as magnitude)
        move    x:(r7+$28),y0        ; |coeff deg10| (>=0, first)
        move    x:(r7+$36),y1        ; P10 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=11 (variable sign, stored signed)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$36),y0        ; P10 (>=0, second)
        mpy     y1,y0,b                   ; P10*XC = deg-11 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$29),y0        ; SIGNED coeff deg11 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=12 (sub, stored as magnitude)
        move    x:(r7+$2A),y0        ; |coeff deg12| (>=0, first)
        move    x:(r7+$37),y1        ; P12 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=13 (variable sign, stored signed)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$37),y0        ; P12 (>=0, second)
        mpy     y1,y0,b                   ; P12*XC = deg-13 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$2B),y0        ; SIGNED coeff deg13 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=14 (add, stored as magnitude)
        move    x:(r7+$2C),y0        ; |coeff deg14| (>=0, first)
        move    x:(r7+$38),y1        ; P14 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=15 (variable sign, stored signed)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$38),y0        ; P14 (>=0, second)
        mpy     y1,y0,b                   ; P14*XC = deg-15 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$2D),y0        ; SIGNED coeff deg15 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

        asl     #$7,a,a                   ; undo the /128 coefficient headroom
                                          ; (POLY_SHIFT=7 -- see
                                          ; sim_phoenix_fixed_v2.py header pt 3)
        move    a,x:(r7+$39)            ; X4

; ---- X3 blend: G0 selects X2S_SAFE (g0=1) vs X_TRIMMED_BY32
; (g0=0), both /32 scale already -- sim_phoenix_fixed_v2 header
; pt 5a. X3S_BY32 = X_TRIMMED_BY32 + G0*(X2S_SAFE-X_TRIMMED_BY32) ----
        move    x:(r7+$30),a
        move    x:(r7+$2E),b
        sub     b,a                       ; a = X2S_SAFE - X_TRIMMED_BY32
        move    a,y1                      ; (signed, first)
        move    x:(r7+$1C),y0            ; G0 (>=0, second)
        mpy     y1,y0,a
        move    x:(r7+$2E),b
        add     b,a                       ; a = X3S_BY32
        move    a,x:(r7+$1b)             ; stash X3S_BY32 -- the SAFE
                                          ; (un-boosted, /32 scale) value,
                                          ; NOT true-scale TRUE_X3. An
                                          ; earlier draft did the asl #5
                                          ; HERE and stashed the boosted
                                          ; TRUE_X3 result straight to this
                                          ; plain r7 cell -- exactly the
                                          ; 'never store a boosted value to
                                          ; r7/plain-register' bug this
                                          ; project's own v1 session (Bug C)
                                          ; already named, caught here by
                                          ; verify_phoenix_asm_v2.py wrapping
                                          ; TRUE_X3 silently (mod 2.0) on any
                                          ; sample where |X3S_BY32|>=1/32.
                                          ; Fixed by stashing the safe value
                                          ; and doing the asl #5 fresh at the
                                          ; use site instead (below).

; ---- X4_PP20 = X4*PP20 (safe, small -- stored) ----
        move    x:(r7+$39),y1            ; X4 (signed, first)
        move    x:(r7+$b),y0             ; PP20 (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$3A)            ; X4_PP20

; ---- X5 = Phoenix_sat(X4_PP20 + TRUE_X3) ----
        move    x:(r7+$1b),a             ; X3S_BY32 (safe, /32 scale)
        asl     #$5,a,a                   ; a = TRUE_X3, computed fresh here
                                          ; (transient -- never touches a
                                          ; plain r7 cell while boosted)
        move    a,b                       ; b = TRUE_X3 (wide accumulator,
                                          ; safe to hold the boosted value)
        move    x:(r7+$3A),a
        add     b,a                       ; a = X5_INPUT (transient)
        move    a,b                       ; b = P (stash)
        move    #>$800000,x0            ; LO = -1.0 true, exact
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a                   ; a = max(P,LO) = M
        move    a,b
        move    #>$7FFFFF,x0            ; HI = Q123_MAX true, exact
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b
        asr     #$1,b,b                   ; b = min(M,HI), SECOND halving --
                                          ; see this module's header on why
                                          ; this differs from tapehead.asm's
                                          ; own apparent clamp sequence
        move    b,a                       ; a = clamped(P, -1, Q123_MAX)
        move    a,x:(r7+$31)            ; XC
; ---- base powers: P2=XC^2, P4=P2^2, P6=P4*P2, P8=P4^2 ----
; ---- (all even powers of a real number -- guaranteed >=0) ----
        move    x:(r7+$31),x0
        move    x0,x1
        mpy     x0,x1,a                   ; P2 = XC*XC (both same sign or
                                          ; zero -- >=0 either way, safe)
        move    a,x:(r7+$32)
        move    a,y0                     ; P2 (kept live in y0 -- mpy
                                          ; never modifies its own source
                                          ; registers, so y0 is still
                                          ; valid for the P6 step below)
        mpy     y0,y0,a                   ; P4 = P2*P2 (P2>=0, safe)
        move    a,x:(r7+$33)
        move    a,y1                     ; P4, freshly captured from `a`
                                          ; right after the store above --
                                          ; NOT the same as an earlier draft
                                          ; of this block, which reused y1
                                          ; still holding P2 (from before
                                          ; the P4 step) here instead,
                                          ; silently computing P2*P2 (=P4)
                                          ; a second time rather than
                                          ; P4*P2 -- a real stale-register
                                          ; bug caught by
                                          ; verify_phoenix_asm_v2.py (it
                                          ; corrupted P6 for every Type,
                                          ; degree-7's own composite power,
                                          ; AND P14=P8*P6 downstream --
                                          ; present in gen_phoenix_asm_
                                          ; blocks.py's v1 gen_poly_block()
                                          ; too, likely the real explanation
                                          ; for v1's own larger-than-
                                          ; expected 3.1e-2 measured error)
        mpy     y1,y0,a                   ; P6 = P4*P2 (both >=0, safe)
        move    a,x:(r7+$34)
        move    x:(r7+$33),x1
        mpy     x1,x1,a                   ; P8 = P4*P4 (P4>=0, safe)
        move    a,x:(r7+$35)

; ---- P10=P8*P2, P12=P8*P4, P14=P8*P6 (all >=0, safe) ----
        move    x:(r7+$35),x1
        move    x:(r7+$32),y0
        mpy     x1,y0,a                   ; P10 = P8*P2
        move    a,x:(r7+$36)
        move    x:(r7+$35),x1
        move    x:(r7+$33),y0
        mpy     x1,y0,a                   ; P12 = P8*P4
        move    a,x:(r7+$37)
        move    x:(r7+$35),x1
        move    x:(r7+$34),y0
        mpy     x1,y0,a                   ; P14 = P8*P6
        move    a,x:(r7+$38)

; ---- 15-term running sum, coefficients read from r7 (selected per
; Type at precompute), accumulated directly in `a` ----
; deg=1 (add, stored as magnitude)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$1F),y0        ; |coeff deg1| (>=0, second)
        mpy     y1,y0,b
        move    b,a                      ; seed running sum

; deg=2 (add, stored as magnitude)
        move    x:(r7+$20),y0        ; |coeff deg2| (>=0, first)
        move    x:(r7+$32),y1        ; P2 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=3 (sub, stored as magnitude)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$32),y0        ; P2 (>=0, second)
        mpy     y1,y0,b                   ; P2*XC = deg-3 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$21),y0        ; |coeff deg3| (>=0, second)
        mpy     y1,y0,b
        sub     b,a

; deg=4 (sub, stored as magnitude)
        move    x:(r7+$22),y0        ; |coeff deg4| (>=0, first)
        move    x:(r7+$33),y1        ; P4 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=5 (variable sign, stored signed)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$33),y0        ; P4 (>=0, second)
        mpy     y1,y0,b                   ; P4*XC = deg-5 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$23),y0        ; SIGNED coeff deg5 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=6 (add, stored as magnitude)
        move    x:(r7+$24),y0        ; |coeff deg6| (>=0, first)
        move    x:(r7+$34),y1        ; P6 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=7 (sub, stored as magnitude)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$34),y0        ; P6 (>=0, second)
        mpy     y1,y0,b                   ; P6*XC = deg-7 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$25),y0        ; |coeff deg7| (>=0, second)
        mpy     y1,y0,b
        sub     b,a

; deg=8 (sub, stored as magnitude)
        move    x:(r7+$26),y0        ; |coeff deg8| (>=0, first)
        move    x:(r7+$35),y1        ; P8 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=9 (add, stored as magnitude)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$35),y0        ; P8 (>=0, second)
        mpy     y1,y0,b                   ; P8*XC = deg-9 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$27),y0        ; |coeff deg9| (>=0, second)
        mpy     y1,y0,b
        add     b,a

; deg=10 (add, stored as magnitude)
        move    x:(r7+$28),y0        ; |coeff deg10| (>=0, first)
        move    x:(r7+$36),y1        ; P10 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=11 (variable sign, stored signed)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$36),y0        ; P10 (>=0, second)
        mpy     y1,y0,b                   ; P10*XC = deg-11 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$29),y0        ; SIGNED coeff deg11 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=12 (sub, stored as magnitude)
        move    x:(r7+$2A),y0        ; |coeff deg12| (>=0, first)
        move    x:(r7+$37),y1        ; P12 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=13 (variable sign, stored signed)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$37),y0        ; P12 (>=0, second)
        mpy     y1,y0,b                   ; P12*XC = deg-13 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$2B),y0        ; SIGNED coeff deg13 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=14 (add, stored as magnitude)
        move    x:(r7+$2C),y0        ; |coeff deg14| (>=0, first)
        move    x:(r7+$38),y1        ; P14 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=15 (variable sign, stored signed)
        move    x:(r7+$31),y1        ; XC (signed, first)
        move    x:(r7+$38),y0        ; P14 (>=0, second)
        mpy     y1,y0,b                   ; P14*XC = deg-15 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$2D),y0        ; SIGNED coeff deg15 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

        asl     #$7,a,a                   ; undo the /128 coefficient headroom
                                          ; (POLY_SHIFT=7 -- see
                                          ; sim_phoenix_fixed_v2.py header pt 3)
        move    a,x:(r7+$3B)            ; X5

; ---- one-pole smoother (v1, unchanged) ----
        move    x:(r7+$0),y1        ; S (old, signed, first)
        move    x:(r7+$6),y0             ; LPF_K_COMP (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$3C)            ; TERM_A
        move    x:(r7+$3B),y1            ; X5 (signed, first)
        move    x:(r7+$5),y0             ; LPF_K (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$3D)            ; TERM_B
        move    x:(r7+$3C),a
        move    x:(r7+$3D),b
        add     b,a                       ; a = S_NEW
        move    a,x:(r7+$3E)            ; S_NEW
        move    a,x:(r7+$0)            ; commit new S

; ---- y_pre via Y_SCALE_HALF/Y_SCALE_P24_X32_HALF (sim_phoenix_
; fixed_v2 header pt 5c) -- asr #4, not v1's asr #5 (Y_SCALE_HALF
; already carries one of the five halvings) ----
        move    x:(r7+$3E),y1            ; S_NEW (signed, first)
        move    x:(r7+$1D),y0            ; Y_SCALE_HALF (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$3F)            ; TERM_C
        move    x:(r7+$2E),y1        ; X_TRIMMED_BY32 (signed, first)
        move    x:(r7+$c),y0             ; Y_SCALE_P24_X32_HALF (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$40)            ; TERM_D
        move    x:(r7+$3F),a
        move    x:(r7+$40),b
        sub     b,a                       ; a = y_pre_half (small)
        asr     #$4,a,a                   ; a = y_pre_by32
        move    a,b
        move    x:(r7+$2E),a        ; X_TRIMMED_BY32
        add     b,a                       ; a = Y_BY32 (pre auto-gain)

; ---- Auto Gain (v1, unchanged) ----
        move    a,y1                      ; Y_BY32 (signed, first)
        move    x:(r7+$d),y0             ; AUTO_GAIN (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$41)            ; Y_BY32 (post auto-gain)

        move    x:(r7+$2E),a        ; commit new PREV_X_BY32 state
        move    a,x:(r7+$1)

; ---- Output Trim (v1, unchanged) ----
        move    x:(r7+$41),y1        ; Y_BY32 (signed, first)
        move    x:(r7+$f),y0             ; OUTPUT_TRIM_K_BY2 (>=0, second)
        mpy     y1,y0,a
        asl     #$6,a,a                   ; a = y_final (caller's store
                                          ; saturates naturally)
        rts

phoenix_r:
; ---- Input Trim, straight into /32 scale (v1, unchanged) ----
        move    a,y1                     ; raw x (signed, first)
        move    x:(r7+$e),y0             ; INPUT_TRIM_K_BY32 (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$42)            ; X_TRIMMED_BY32

; ---- X1S/X2S_SAFE, /32 scale (v1, unchanged) ----
        move    x:(r7+$42),y1        ; X_TRIMMED_BY32 (signed, first)
        move    x:(r7+$4),y0             ; HPF_K (>=0, second)
        mpy     y1,y0,a
        move    x:(r7+$42),b
        add     b,a                       ; + X_TRIMMED_BY32
        move    x:(r7+$3),b        ; PREV_X_BY32 (old)
        sub     b,a                       ; a = X1S
        move    a,x:(r7+$43)            ; X1S

        move    x:(r7+$43),y1            ; X1S (signed, first)
        move    x:(r7+$7),y0             ; F1 (>=0, second)
        mpy     y1,y0,a
        move    x:(r7+$43),b
        add     b,a                       ; a = X2S (/32 scale)
        move    a,x:(r7+$44)            ; X2S_SAFE (/32 scale)

; ---- X4 input: X2S_SAFE*X4_MULT at /32 scale (X4_MULT is
; PROCESSING for Luster, ~1.0 otherwise -- sim_phoenix_fixed_v2
; header pt 5b), THEN asl #5 straight into the clamp -- never a
; boosted value in a plain register (same discipline as v1's
; TRUE_X2, see gen_phoenix_asm.py's own header point 2). ----
        move    x:(r7+$44),y1        ; X2S_SAFE (signed, first)
        move    x:(r7+$1E),y0            ; X4_MULT (>=0, second)
        mpy     y1,y0,a                   ; X4_INPUT_BY32
        asl     #$5,a,a                   ; a = X4_INPUT_TRUE (transient)
        move    a,b                       ; b = P (stash)
        move    #>$800000,x0            ; LO = -1.0 true, exact
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a                   ; a = max(P,LO) = M
        move    a,b
        move    #>$7FFFFF,x0            ; HI = Q123_MAX true, exact
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b
        asr     #$1,b,b                   ; b = min(M,HI), SECOND halving --
                                          ; see this module's header on why
                                          ; this differs from tapehead.asm's
                                          ; own apparent clamp sequence
        move    b,a                       ; a = clamped(P, -1, Q123_MAX)
        move    a,x:(r7+$45)            ; XC
; ---- base powers: P2=XC^2, P4=P2^2, P6=P4*P2, P8=P4^2 ----
; ---- (all even powers of a real number -- guaranteed >=0) ----
        move    x:(r7+$45),x0
        move    x0,x1
        mpy     x0,x1,a                   ; P2 = XC*XC (both same sign or
                                          ; zero -- >=0 either way, safe)
        move    a,x:(r7+$46)
        move    a,y0                     ; P2 (kept live in y0 -- mpy
                                          ; never modifies its own source
                                          ; registers, so y0 is still
                                          ; valid for the P6 step below)
        mpy     y0,y0,a                   ; P4 = P2*P2 (P2>=0, safe)
        move    a,x:(r7+$47)
        move    a,y1                     ; P4, freshly captured from `a`
                                          ; right after the store above --
                                          ; NOT the same as an earlier draft
                                          ; of this block, which reused y1
                                          ; still holding P2 (from before
                                          ; the P4 step) here instead,
                                          ; silently computing P2*P2 (=P4)
                                          ; a second time rather than
                                          ; P4*P2 -- a real stale-register
                                          ; bug caught by
                                          ; verify_phoenix_asm_v2.py (it
                                          ; corrupted P6 for every Type,
                                          ; degree-7's own composite power,
                                          ; AND P14=P8*P6 downstream --
                                          ; present in gen_phoenix_asm_
                                          ; blocks.py's v1 gen_poly_block()
                                          ; too, likely the real explanation
                                          ; for v1's own larger-than-
                                          ; expected 3.1e-2 measured error)
        mpy     y1,y0,a                   ; P6 = P4*P2 (both >=0, safe)
        move    a,x:(r7+$48)
        move    x:(r7+$47),x1
        mpy     x1,x1,a                   ; P8 = P4*P4 (P4>=0, safe)
        move    a,x:(r7+$49)

; ---- P10=P8*P2, P12=P8*P4, P14=P8*P6 (all >=0, safe) ----
        move    x:(r7+$49),x1
        move    x:(r7+$46),y0
        mpy     x1,y0,a                   ; P10 = P8*P2
        move    a,x:(r7+$4A)
        move    x:(r7+$49),x1
        move    x:(r7+$47),y0
        mpy     x1,y0,a                   ; P12 = P8*P4
        move    a,x:(r7+$4B)
        move    x:(r7+$49),x1
        move    x:(r7+$48),y0
        mpy     x1,y0,a                   ; P14 = P8*P6
        move    a,x:(r7+$4C)

; ---- 15-term running sum, coefficients read from r7 (selected per
; Type at precompute), accumulated directly in `a` ----
; deg=1 (add, stored as magnitude)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$1F),y0        ; |coeff deg1| (>=0, second)
        mpy     y1,y0,b
        move    b,a                      ; seed running sum

; deg=2 (add, stored as magnitude)
        move    x:(r7+$20),y0        ; |coeff deg2| (>=0, first)
        move    x:(r7+$46),y1        ; P2 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=3 (sub, stored as magnitude)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$46),y0        ; P2 (>=0, second)
        mpy     y1,y0,b                   ; P2*XC = deg-3 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$21),y0        ; |coeff deg3| (>=0, second)
        mpy     y1,y0,b
        sub     b,a

; deg=4 (sub, stored as magnitude)
        move    x:(r7+$22),y0        ; |coeff deg4| (>=0, first)
        move    x:(r7+$47),y1        ; P4 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=5 (variable sign, stored signed)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$47),y0        ; P4 (>=0, second)
        mpy     y1,y0,b                   ; P4*XC = deg-5 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$23),y0        ; SIGNED coeff deg5 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=6 (add, stored as magnitude)
        move    x:(r7+$24),y0        ; |coeff deg6| (>=0, first)
        move    x:(r7+$48),y1        ; P6 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=7 (sub, stored as magnitude)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$48),y0        ; P6 (>=0, second)
        mpy     y1,y0,b                   ; P6*XC = deg-7 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$25),y0        ; |coeff deg7| (>=0, second)
        mpy     y1,y0,b
        sub     b,a

; deg=8 (sub, stored as magnitude)
        move    x:(r7+$26),y0        ; |coeff deg8| (>=0, first)
        move    x:(r7+$49),y1        ; P8 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=9 (add, stored as magnitude)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$49),y0        ; P8 (>=0, second)
        mpy     y1,y0,b                   ; P8*XC = deg-9 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$27),y0        ; |coeff deg9| (>=0, second)
        mpy     y1,y0,b
        add     b,a

; deg=10 (add, stored as magnitude)
        move    x:(r7+$28),y0        ; |coeff deg10| (>=0, first)
        move    x:(r7+$4A),y1        ; P10 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=11 (variable sign, stored signed)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$4A),y0        ; P10 (>=0, second)
        mpy     y1,y0,b                   ; P10*XC = deg-11 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$29),y0        ; SIGNED coeff deg11 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=12 (sub, stored as magnitude)
        move    x:(r7+$2A),y0        ; |coeff deg12| (>=0, first)
        move    x:(r7+$4B),y1        ; P12 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=13 (variable sign, stored signed)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$4B),y0        ; P12 (>=0, second)
        mpy     y1,y0,b                   ; P12*XC = deg-13 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$2B),y0        ; SIGNED coeff deg13 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=14 (add, stored as magnitude)
        move    x:(r7+$2C),y0        ; |coeff deg14| (>=0, first)
        move    x:(r7+$4C),y1        ; P14 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=15 (variable sign, stored signed)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$4C),y0        ; P14 (>=0, second)
        mpy     y1,y0,b                   ; P14*XC = deg-15 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$2D),y0        ; SIGNED coeff deg15 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

        asl     #$7,a,a                   ; undo the /128 coefficient headroom
                                          ; (POLY_SHIFT=7 -- see
                                          ; sim_phoenix_fixed_v2.py header pt 3)
        move    a,x:(r7+$4D)            ; X4

; ---- X3 blend: G0 selects X2S_SAFE (g0=1) vs X_TRIMMED_BY32
; (g0=0), both /32 scale already -- sim_phoenix_fixed_v2 header
; pt 5a. X3S_BY32 = X_TRIMMED_BY32 + G0*(X2S_SAFE-X_TRIMMED_BY32) ----
        move    x:(r7+$44),a
        move    x:(r7+$42),b
        sub     b,a                       ; a = X2S_SAFE - X_TRIMMED_BY32
        move    a,y1                      ; (signed, first)
        move    x:(r7+$1C),y0            ; G0 (>=0, second)
        mpy     y1,y0,a
        move    x:(r7+$42),b
        add     b,a                       ; a = X3S_BY32
        move    a,x:(r7+$1b)             ; stash X3S_BY32 -- the SAFE
                                          ; (un-boosted, /32 scale) value,
                                          ; NOT true-scale TRUE_X3. An
                                          ; earlier draft did the asl #5
                                          ; HERE and stashed the boosted
                                          ; TRUE_X3 result straight to this
                                          ; plain r7 cell -- exactly the
                                          ; 'never store a boosted value to
                                          ; r7/plain-register' bug this
                                          ; project's own v1 session (Bug C)
                                          ; already named, caught here by
                                          ; verify_phoenix_asm_v2.py wrapping
                                          ; TRUE_X3 silently (mod 2.0) on any
                                          ; sample where |X3S_BY32|>=1/32.
                                          ; Fixed by stashing the safe value
                                          ; and doing the asl #5 fresh at the
                                          ; use site instead (below).

; ---- X4_PP20 = X4*PP20 (safe, small -- stored) ----
        move    x:(r7+$4D),y1            ; X4 (signed, first)
        move    x:(r7+$b),y0             ; PP20 (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$4E)            ; X4_PP20

; ---- X5 = Phoenix_sat(X4_PP20 + TRUE_X3) ----
        move    x:(r7+$1b),a             ; X3S_BY32 (safe, /32 scale)
        asl     #$5,a,a                   ; a = TRUE_X3, computed fresh here
                                          ; (transient -- never touches a
                                          ; plain r7 cell while boosted)
        move    a,b                       ; b = TRUE_X3 (wide accumulator,
                                          ; safe to hold the boosted value)
        move    x:(r7+$4E),a
        add     b,a                       ; a = X5_INPUT (transient)
        move    a,b                       ; b = P (stash)
        move    #>$800000,x0            ; LO = -1.0 true, exact
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a                   ; a = max(P,LO) = M
        move    a,b
        move    #>$7FFFFF,x0            ; HI = Q123_MAX true, exact
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b
        asr     #$1,b,b                   ; b = min(M,HI), SECOND halving --
                                          ; see this module's header on why
                                          ; this differs from tapehead.asm's
                                          ; own apparent clamp sequence
        move    b,a                       ; a = clamped(P, -1, Q123_MAX)
        move    a,x:(r7+$45)            ; XC
; ---- base powers: P2=XC^2, P4=P2^2, P6=P4*P2, P8=P4^2 ----
; ---- (all even powers of a real number -- guaranteed >=0) ----
        move    x:(r7+$45),x0
        move    x0,x1
        mpy     x0,x1,a                   ; P2 = XC*XC (both same sign or
                                          ; zero -- >=0 either way, safe)
        move    a,x:(r7+$46)
        move    a,y0                     ; P2 (kept live in y0 -- mpy
                                          ; never modifies its own source
                                          ; registers, so y0 is still
                                          ; valid for the P6 step below)
        mpy     y0,y0,a                   ; P4 = P2*P2 (P2>=0, safe)
        move    a,x:(r7+$47)
        move    a,y1                     ; P4, freshly captured from `a`
                                          ; right after the store above --
                                          ; NOT the same as an earlier draft
                                          ; of this block, which reused y1
                                          ; still holding P2 (from before
                                          ; the P4 step) here instead,
                                          ; silently computing P2*P2 (=P4)
                                          ; a second time rather than
                                          ; P4*P2 -- a real stale-register
                                          ; bug caught by
                                          ; verify_phoenix_asm_v2.py (it
                                          ; corrupted P6 for every Type,
                                          ; degree-7's own composite power,
                                          ; AND P14=P8*P6 downstream --
                                          ; present in gen_phoenix_asm_
                                          ; blocks.py's v1 gen_poly_block()
                                          ; too, likely the real explanation
                                          ; for v1's own larger-than-
                                          ; expected 3.1e-2 measured error)
        mpy     y1,y0,a                   ; P6 = P4*P2 (both >=0, safe)
        move    a,x:(r7+$48)
        move    x:(r7+$47),x1
        mpy     x1,x1,a                   ; P8 = P4*P4 (P4>=0, safe)
        move    a,x:(r7+$49)

; ---- P10=P8*P2, P12=P8*P4, P14=P8*P6 (all >=0, safe) ----
        move    x:(r7+$49),x1
        move    x:(r7+$46),y0
        mpy     x1,y0,a                   ; P10 = P8*P2
        move    a,x:(r7+$4A)
        move    x:(r7+$49),x1
        move    x:(r7+$47),y0
        mpy     x1,y0,a                   ; P12 = P8*P4
        move    a,x:(r7+$4B)
        move    x:(r7+$49),x1
        move    x:(r7+$48),y0
        mpy     x1,y0,a                   ; P14 = P8*P6
        move    a,x:(r7+$4C)

; ---- 15-term running sum, coefficients read from r7 (selected per
; Type at precompute), accumulated directly in `a` ----
; deg=1 (add, stored as magnitude)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$1F),y0        ; |coeff deg1| (>=0, second)
        mpy     y1,y0,b
        move    b,a                      ; seed running sum

; deg=2 (add, stored as magnitude)
        move    x:(r7+$20),y0        ; |coeff deg2| (>=0, first)
        move    x:(r7+$46),y1        ; P2 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=3 (sub, stored as magnitude)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$46),y0        ; P2 (>=0, second)
        mpy     y1,y0,b                   ; P2*XC = deg-3 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$21),y0        ; |coeff deg3| (>=0, second)
        mpy     y1,y0,b
        sub     b,a

; deg=4 (sub, stored as magnitude)
        move    x:(r7+$22),y0        ; |coeff deg4| (>=0, first)
        move    x:(r7+$47),y1        ; P4 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=5 (variable sign, stored signed)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$47),y0        ; P4 (>=0, second)
        mpy     y1,y0,b                   ; P4*XC = deg-5 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$23),y0        ; SIGNED coeff deg5 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=6 (add, stored as magnitude)
        move    x:(r7+$24),y0        ; |coeff deg6| (>=0, first)
        move    x:(r7+$48),y1        ; P6 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=7 (sub, stored as magnitude)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$48),y0        ; P6 (>=0, second)
        mpy     y1,y0,b                   ; P6*XC = deg-7 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$25),y0        ; |coeff deg7| (>=0, second)
        mpy     y1,y0,b
        sub     b,a

; deg=8 (sub, stored as magnitude)
        move    x:(r7+$26),y0        ; |coeff deg8| (>=0, first)
        move    x:(r7+$49),y1        ; P8 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=9 (add, stored as magnitude)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$49),y0        ; P8 (>=0, second)
        mpy     y1,y0,b                   ; P8*XC = deg-9 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$27),y0        ; |coeff deg9| (>=0, second)
        mpy     y1,y0,b
        add     b,a

; deg=10 (add, stored as magnitude)
        move    x:(r7+$28),y0        ; |coeff deg10| (>=0, first)
        move    x:(r7+$4A),y1        ; P10 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=11 (variable sign, stored signed)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$4A),y0        ; P10 (>=0, second)
        mpy     y1,y0,b                   ; P10*XC = deg-11 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$29),y0        ; SIGNED coeff deg11 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=12 (sub, stored as magnitude)
        move    x:(r7+$2A),y0        ; |coeff deg12| (>=0, first)
        move    x:(r7+$4B),y1        ; P12 (>=0, second)
        mpy     y0,y1,b
        sub     b,a

; deg=13 (variable sign, stored signed)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$4B),y0        ; P12 (>=0, second)
        mpy     y1,y0,b                   ; P12*XC = deg-13 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$2B),y0        ; SIGNED coeff deg13 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

; deg=14 (add, stored as magnitude)
        move    x:(r7+$2C),y0        ; |coeff deg14| (>=0, first)
        move    x:(r7+$4C),y1        ; P14 (>=0, second)
        mpy     y0,y1,b
        add     b,a

; deg=15 (variable sign, stored signed)
        move    x:(r7+$45),y1        ; XC (signed, first)
        move    x:(r7+$4C),y0        ; P14 (>=0, second)
        mpy     y1,y0,b                   ; P14*XC = deg-15 power (signed)
        move    b,y1                     ; (signed, first) -- `a` untouched
        move    x:(r7+$2D),y0        ; SIGNED coeff deg15 (per-Type
                                          ; sign, second -- see this file's
                                          ; own header on why this is new)
        mpy     y1,y0,b
        add     b,a                      ; sign already baked into
                                          ; the stored coefficient

        asl     #$7,a,a                   ; undo the /128 coefficient headroom
                                          ; (POLY_SHIFT=7 -- see
                                          ; sim_phoenix_fixed_v2.py header pt 3)
        move    a,x:(r7+$4F)            ; X5

; ---- one-pole smoother (v1, unchanged) ----
        move    x:(r7+$2),y1        ; S (old, signed, first)
        move    x:(r7+$6),y0             ; LPF_K_COMP (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$50)            ; TERM_A
        move    x:(r7+$4F),y1            ; X5 (signed, first)
        move    x:(r7+$5),y0             ; LPF_K (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$51)            ; TERM_B
        move    x:(r7+$50),a
        move    x:(r7+$51),b
        add     b,a                       ; a = S_NEW
        move    a,x:(r7+$52)            ; S_NEW
        move    a,x:(r7+$2)            ; commit new S

; ---- y_pre via Y_SCALE_HALF/Y_SCALE_P24_X32_HALF (sim_phoenix_
; fixed_v2 header pt 5c) -- asr #4, not v1's asr #5 (Y_SCALE_HALF
; already carries one of the five halvings) ----
        move    x:(r7+$52),y1            ; S_NEW (signed, first)
        move    x:(r7+$1D),y0            ; Y_SCALE_HALF (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$53)            ; TERM_C
        move    x:(r7+$42),y1        ; X_TRIMMED_BY32 (signed, first)
        move    x:(r7+$c),y0             ; Y_SCALE_P24_X32_HALF (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$54)            ; TERM_D
        move    x:(r7+$53),a
        move    x:(r7+$54),b
        sub     b,a                       ; a = y_pre_half (small)
        asr     #$4,a,a                   ; a = y_pre_by32
        move    a,b
        move    x:(r7+$42),a        ; X_TRIMMED_BY32
        add     b,a                       ; a = Y_BY32 (pre auto-gain)

; ---- Auto Gain (v1, unchanged) ----
        move    a,y1                      ; Y_BY32 (signed, first)
        move    x:(r7+$d),y0             ; AUTO_GAIN (>=0, second)
        mpy     y1,y0,a
        move    a,x:(r7+$55)            ; Y_BY32 (post auto-gain)

        move    x:(r7+$42),a        ; commit new PREV_X_BY32 state
        move    a,x:(r7+$3)

; ---- Output Trim (v1, unchanged) ----
        move    x:(r7+$55),y1        ; Y_BY32 (signed, first)
        move    x:(r7+$f),y0             ; OUTPUT_TRIM_K_BY2 (>=0, second)
        mpy     y1,y0,a
        asl     #$6,a,a                   ; a = y_final (caller's store
                                          ; saturates naturally)
        rts

; ---------------------------------------------------------------------------
; poly6 -- shared degree-5 polynomial evaluator, unchanged from v1.
; ---------------------------------------------------------------------------
poly6:
        move    x:(r7+$15),a             ; c0 (seed -- p0*t^0, loaded
                                          ; directly, not multiplied)

        move    x:(r7+$10),y1            ; t^1 (variable, first)
        move    x:(r7+$16),y0            ; c1 (coefficient, second)
        mpy     y1,y0,b
        add     b,a

        move    x:(r7+$11),y1            ; t^2
        move    x:(r7+$17),y0            ; c2
        mpy     y1,y0,b
        add     b,a

        move    x:(r7+$12),y1            ; t^3
        move    x:(r7+$18),y0            ; c3
        mpy     y1,y0,b
        add     b,a

        move    x:(r7+$13),y1            ; t^4
        move    x:(r7+$19),y0            ; c4
        mpy     y1,y0,b
        add     b,a

        move    x:(r7+$14),y1            ; t^5
        move    x:(r7+$1a),y0            ; c5
        mpy     y1,y0,b
        add     b,a
        rts
