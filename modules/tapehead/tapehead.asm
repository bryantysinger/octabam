; ---------------------------------------------------------------------------
; TAPEHEAD v1 -- octabam module, port of JClones_TapeHead.jsfx (MIT), a
; small analog-tape-saturation effect: a 2-state coupled recursion (not a
; biquad -- see the derivation below) driving two cubic "smoothstep"
; waveshapers plus one more term, summed and trimmed.
;
; STATUS: third draft. Every formula is numerically validated in Python
; against the float JSFX reference (sim_tapehead.py) via a full
; fixed-point model (sim_tapehead_fixed.py) that mirrors this file's own
; scaling/shift/quantization choices exactly -- worst peak error 7.3e-5,
; worst RMS error 0.003%, across every Color x Drive x Trim combination
; against impulse/step/sine stress signals (unaffected by either rewrite
; below -- both are exact algebraic transforms of the same arithmetic, see
; each rewrite's own comment for why). Two real `make check
; REMIX=tapehead_test` runs so far, both against `cycle_count.py`, same
; error both times: "bsr callee tapehead_l is not straight-line".
;   Round 1 (first draft): tapehead_l/tapehead_r/smoothstep used ordinary
;   forward branches (two clamps). Read that as "conditional branches are
;   the problem" and made them branchless via the (A+B+/-|A-B|)/2 identity
;   (fattener.asm's own proven d8-clamp sequence) -- but LEFT tapehead_l
;   calling `bsr smoothstep` and a new `bsr clamp_y3`, reasoning that a
;   bsr to a genuinely straight-line callee should be fine since only
;   conditional branches were named in the error. Wrong: round 2 came back
;   with the IDENTICAL error, proving the checker does not recurse into a
;   nested bsr target to see whether IT is straight-line -- it simply
;   requires the bsr callee reached from the sample loop to contain no
;   control-transfer instruction of ANY kind (no bra/bcc, and no further
;   bsr/rts pairs either), full stop. This is exactly what Fattener's own
;   session's HANDOFF.md already said in so many words -- "inlined tanh_sat
;   per channel for that reason" -- which this draft should have taken
;   literally the first time instead of reading it as being only about
;   conditional branches.
;   Round 2 fix (this draft): smoothstep and clamp_y3 are no longer
;   separate bsr'd subroutines at all -- their bodies are inlined directly
;   into tapehead_l/tapehead_r (smoothstep twice per channel, once for
;   y1n and once for y2n; clamp_y3 once per channel), so tapehead_l and
;   tapehead_r are now single straight-line blocks ending in one `rts`
;   each, with zero bsr/bra/bcc anywhere inside them. poly6 keeps its own
;   `bsr` (called only from `proc:`'s precompute, outside the `do
;   n7,>tapeend` sample loop, so it was never subject to this rule and
;   needed no change).
; Still NOT run past this point -- this session has file stage/read/commit
; only, no device_bash, so nothing has touched dsp_asm beyond the two
; `make check` transcripts pasted back so far. Run it again and paste the
; result.
;
; WHY THIS SHAPE (read before touching the constants):
;
; 1. TapeHead's y1/y2 state is NOT naturally bounded to +/-1, same class of
;    problem as Inflator's TPT integrator (see inflator.asm's own header).
;    Measured (not assumed): for ANY input sequence bounded by +/-1, the
;    exact worst-case |y1|/|y2| is the L1 norm of each state's impulse
;    response (computed analytically per Color, in sim_tapehead_fixed.py's
;    own header) -- 1.40 to 1.46 for y1, 1.40 to 1.95 for y2. Storing state
;    at HALF (Inflator's own Km1 fix) would leave only ~2% headroom against
;    the worst case -- too tight to trust without hardware to check it on.
;    This module stores y1/y2 (and the transient y3) at QUARTER instead
;    (headroom shift 2, true range to just under +/-4, ~2x the measured
;    worst case), and folds that /4 factor straight through the recursion
;    algebraically:
;        Y1[n] = Y1[n-1] + k2*Y2[n-1]
;        Y3[n] = k1*Y1[n] + Y2[n-1] - Xs[n]      (Xs = x/4, the ONLY extra
;                                                  step -- x itself is never
;                                                  needed unshifted again)
;        Y2[n] = Y2[n-1] + k3*Y3[n]
;    identical in form to the JSFX's own un-scaled recursion, because every
;    term on both sides of every line carries the same /4 factor and
;    cancels. No per-term undo-shift inside the recursion itself -- only at
;    the three points something derived from the state has to become an
;    mpy operand or leave the channel routine (drive_k into smoothstep(),
;    g3 into the output sum, trim_k at the very end).
;
; 2. Every mpy below follows this project's confirmed-by-testing
;    convention (Inflator's onepole/waveshape headers; CLAUDE.md's mpy
;    trap): the operand that can be NEGATIVE goes first; a guaranteed
;    non-negative magnitude goes second. k3 and g3 are FIXED constants
;    that are ALWAYS negative here (not sometimes-negative data, always --
;    g3 doesn't even depend on any knob), so their MAGNITUDE is what's
;    stored and multiplied (second operand), with the known sign applied
;    afterward as a SUBTRACT instead of an add. This makes every mpy safe
;    regardless of which specific register pair turns out to encode signed
;    vs. mpysu, because the second operand is never negative at runtime.
;    ONE EXCEPTION, flagged where it happens: poly6's coefficient slot
;    (y0) can be negative (DRIVE16's p4 is, see gen_tapehead_constants.py's
;    output) -- this mirrors fattener.asm's own poly6 usage exactly (same
;    y1=variable-first/y0=coefficient-second shape, and Fattener's own
;    polynomial fits also have negative coefficients), but neither
;    CLAUDE.md's mpy-trap list nor Fattener's comments confirm the y1,y0
;    pair specifically -- disassemble poly6's build with a negative
;    coefficient before trusting it, per CLAUDE.md's own rule for any new
;    mpy whose second operand can go negative.
;
; 3. v1 scope, deliberate (not a bug worked around -- same character as
;    Inflator's CLIP=on-only decision):
;      - Clip is always effectively ON. The JSFX's "Clip: off" mode lets
;        internal values run past +/-1 for a softer feel; this hardware's
;        Q1.23 format cannot represent that at all (same reasoning as
;        Inflator's CLIP knob), so v1 doesn't expose the "off" position.
;        Because Clip=on is *also* the JSFX's own default, this changes
;        nothing about the default sound.
;      - The input sample itself needs no explicit clip: it arrives at
;        x:(r0) already a valid Q1.23 value by construction, so the JSFX's
;        input-stage clip() is a no-op on this hardware and is omitted.
;      - The final output clip is FREE: the caller's `move a,x:(r0)`
;        naturally saturates to +/-1 (Inflator's own "LIMITING move"), so
;        no explicit clamp is coded for it -- whatever the recursion/gain
;        stages produce past +/-1 gets hard-limited there, exactly
;        matching TapeHead_clip(y) under hard_clip=on.
;      - Drive and Trim are exposed as smooth 128-position knobs (poly6
;        fits over the knob fraction) rather than the JSFX's 10/22-step
;        integer sliders -- a deliberate UI choice, not a limitation: the
;        underlying formula and range are unchanged, only the granularity,
;        matching how Inflator/Fattener both turn their own knobs into
;        continuous 128-value quantities. Color stays a genuine 3-way
;        select (a different fixed filter frequency per position, not a
;        continuous quantity).
;
; 4. Constants from gen_tapehead_constants.py's math (not hand-typed) --
;    Color's K2/K3_MAG are exact (SR=44100, only 3 possible settings, no
;    runtime sin() on this chip); DRIVE16/TRIM_K are degree-5 poly6 fits
;    over the knob fraction (t = raw/128, no shift needed -- "value<<16
;    already IS value/128 in Q1.23", per inflator.asm's own header); K1
;    and G3_MAG_HALF are single fixed constants with no knob dependence
;    at all (K1=5/7 always; g3 depends only on K1 and a fixed 1.4 pivot
;    that's constant because this project's SR is always under 88.2 kHz).
;
; r7 memory map:
;   $00       L y1 (persistent, true/4)
;   $01       L y2 (persistent, true/4)
;   $02       R y1 (persistent, true/4)
;   $03       R y2 (persistent, true/4)
;   $04       K2       (per-block, Color-selected, >=0)
;   $05       K3_MAG   (per-block, Color-selected, >=0)
;   $06       DRIVE16  (per-block, poly6 of DRIVE knob, >=0)
;   $07       TRIM_K   (per-block, poly6 of TRIM knob, >=0)
;   $08-$0c   poly6 staging: STAGE_X1..X5 (t^1..t^5)
;   $0d-$12   poly6 staging: STAGE_C0..C5 (p0..p5)
;   $20-$25   L channel per-sample scratch: Y1N,Y3,Y2N,Y1SAT,Y2SAT,G3TERM
;   $30-$35   R channel per-sample scratch (mirror of $20-$25)
; Total: $00-$35 (54 words) -- less than Inflator's own ~40 plus its
; waveshape scratch, well under Fattener's 82 (see HANDOFF.md).
; ---------------------------------------------------------------------------

; Constants inlined directly at every use site -- this assembler rejects
; `equ` (see inflator.asm's own header for why). Kept here as a lookup
; table since the raw hex means nothing on its own:
;   Color NORMAL (2100 Hz): K2=$2627A2  K3_MAG=$356AB0
;   Color MEDIUM (3680 Hz): K2=$425882  K3_MAG=$5CE250
;   Color BRIGHT (5000 Hz): K2=$5944C4  K3_MAG=$7CF9E0
;   K1 (5/7, fixed)              = $5B6DB6
;   G3_MAG_HALF (|g3|/2, fixed)  = $4A23CF
;   DRIVE16 poly6 (headroom shift 0): p0=$066576 p1=$0EE664 p2=$0F580E
;                                     p3=$1342CD p4=$FCB5F2 p5=$0B61C8
;   TRIM_K poly6 (headroom shift 2, asl #2 after poly6 returns):
;                                     p0=$1665E5 p1=$C9EFD6 p2=$407484
;                                     p3=$CFA940 p4=$167522 p5=$FB15DA
;   Smoothstep clamp bounds (true/64 scale): +1/64=$01FFFF  -1/64=$FE0000
;   Y3-for-output clamp bounds (true/4 scale): +1/4=$1FFFFF  -1/4=$E00000
; All from gen_tapehead_constants.py's math.

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
; ---- precompute (once per call): Color -> K2/K3_MAG, Drive/Trim knobs ->
; DRIVE16/TRIM_K via the shared poly6 evaluator. None of this runs in the
; per-sample loop, so ordinary branches here carry none of the per-sample
; cycle-budget/bsr-straight-line concerns (same reasoning as Inflator's own
; precompute section, which also branches freely -- see e.g. its SPLIT
; read). -----------------------------------------------------------------

; ---- COLOR: raw 0/1/2 (plain integer, a 3-way select -- not a Q1.23
; fraction, same convention as Inflator's CLIP/SPLIT toggles) ----
; COLOR is page-2 slot 7 (13 Sep 2026: a select may not sit on page 1): the
; SELECT field of the word slot 6 shares, bits 8-15 of r6+$c, shifted back to
; the plain 0/1/2 the branches below expect. `and` leaves A2 stale: a1->x0->a.
        move    x:(r6+$c),a
        and     #>$ff00,a
        move    a1,x0
        move    x0,a
        asr     #$8,a,a
        tst     a
        beq     color_normal
        move    #>$1,x0
        sub     x0,a
        beq     color_medium
; else COLOR==2 (BRIGHT)
        move    #>$5944C4,y0
        move    y0,x:(r7+$4)
        move    #>$7CF9E0,y0
        move    y0,x:(r7+$5)
        bra     color_done
color_normal:
        move    #>$2627A2,y0
        move    y0,x:(r7+$4)
        move    #>$356AB0,y0
        move    y0,x:(r7+$5)
        bra     color_done
color_medium:
        move    #>$425882,y0
        move    y0,x:(r7+$4)
        move    #>$5CE250,y0
        move    y0,x:(r7+$5)
color_done:

; ---- DRIVE: raw 0..127 at x:(r6+$0), t = raw/128 (no shift needed) ----
        move    x:(r6+$0),x0             ; t
        move    x0,x:(r7+$8)             ; STAGE_X1 = t^1
        move    x0,x1
        mpy     x0,x1,a                  ; t^2 (t always >=0 -- safe)
        move    a,x:(r7+$9)
        move    a,y1
        mpy     x0,y1,a                  ; t^3
        move    a,x:(r7+$a)
        move    a,y1
        mpy     x0,y1,a                  ; t^4
        move    a,x:(r7+$b)
        move    a,y1
        mpy     x0,y1,a                  ; t^5
        move    a,x:(r7+$c)

        move    #>$066576,a
        move    a,x:(r7+$d)              ; STAGE_C0 (DRIVE16 p0)
        move    #>$0EE664,a
        move    a,x:(r7+$e)              ; p1
        move    #>$0F580E,a
        move    a,x:(r7+$f)              ; p2
        move    #>$1342CD,a
        move    a,x:(r7+$10)             ; p3
        move    #>$FCB5F2,a
        move    a,x:(r7+$11)             ; p4 (negative -- see header note 2)
        move    #>$0B61C8,a
        move    a,x:(r7+$12)             ; p5
        bsr     poly6
        move    a,x:(r7+$6)              ; DRIVE16 -- no headroom, no asl

; ---- TRIM: raw 0..127 at x:(r6+$1), t = raw/128 ----
        move    x:(r6+$1),x0             ; t
        move    x0,x:(r7+$8)
        move    x0,x1
        mpy     x0,x1,a
        move    a,x:(r7+$9)
        move    a,y1
        mpy     x0,y1,a
        move    a,x:(r7+$a)
        move    a,y1
        mpy     x0,y1,a
        move    a,x:(r7+$b)
        move    a,y1
        mpy     x0,y1,a
        move    a,x:(r7+$c)

        move    #>$1665E5,a
        move    a,x:(r7+$d)              ; TRIM_K p0 (all stored /4 --
        move    #>$C9EFD6,a              ; headroom shift 2, undone below)
        move    a,x:(r7+$e)
        move    #>$407484,a
        move    a,x:(r7+$f)
        move    #>$CFA940,a
        move    a,x:(r7+$10)
        move    #>$167522,a
        move    a,x:(r7+$11)
        move    #>$FB15DA,a
        move    a,x:(r7+$12)
        bsr     poly6
        asl     #$2,a,a                  ; undo TRIM_K's /4 headroom
        move    a,x:(r7+$7)              ; TRIM_K

; ---- sample loop -----------------------------------------------------------
        move    #>$ffffff,m0
        move    #>$1,n0
        do      n7,>tapeend

        move    x:(r0),a
        bsr     tapehead_l
        move    a,x:(r0)

        move    x:(r0+n0),a
        bsr     tapehead_r
        move    a,x:(r0+n0)

        move    #>$2,n0
        move    (r0)+n0
        move    #>$1,n0
tapeend:
        rts

; ---------------------------------------------------------------------------
; tapehead_l / tapehead_r: process one channel end to end. Identical shape,
; different state offsets ($0/$1 vs $2/$3) and scratch bank ($20.. vs
; $30..), written out in full rather than shared via a parameterized
; routine -- same reasoning as Inflator's own onechan_l/onechan_r
; duplication (no confirmed-safe address-register arithmetic in this ABI).
; In: a = raw input sample x (already a valid Q1.23 value -- see header
; note 3, no explicit input clip needed). Out: a = processed sample, trim
; applied; the caller's move to x:(r0)/x:(r0+n0) provides the v1
; hard-clip-on output clamp for free (Inflator's own "LIMITING move").
;
; smoothstep (both calls) and the y3 output-clamp are inlined DIRECTLY here
; rather than bsr'd out -- per this module's second real `make check` run
; (see the file header's STATUS note), the checker requires a bsr callee
; reached from the sample loop to contain ZERO further control-transfer
; instructions of any kind, not just conditional branches: a first attempt
; that left `bsr smoothstep`/`bsr clamp_y3` inside tapehead_l/tapehead_r,
; with smoothstep/clamp_y3 themselves genuinely straight-line, got the
; IDENTICAL "not straight-line" complaint back. Full inlining is exactly
; what Fattener's own session did with tanh_sat for the same reason
; (HANDOFF.md) -- so tapehead_l/tapehead_r are each one unbroken sequence
; of straight-line instructions ending in a single `rts`, no exceptions.
; ---------------------------------------------------------------------------
tapehead_l:
        asr     #$2,a,a                  ; a = Xs = x/4 (the only place the
                                          ; state's /4 headroom factor needs
                                          ; an explicit step -- see header)
        move    a,x0                     ; stash Xs

; ---- y1n = y1_old + k2*y2_old ----
        move    x:(r7+$1),y1             ; y2_old (signed, first)
        move    x:(r7+$4),y0             ; k2 (>=0, second)
        mpy     y1,y0,a
        move    x:(r7+$0),b              ; y1_old
        add     b,a                      ; a = y1n
        move    a,x:(r7+$20)             ; Y1N_L
        move    a,x:(r7+$0)              ; commit new y1 (old y1 now dead)

; ---- y3 = k1*y1n + y2_old - Xs ----
        move    x:(r7+$20),y1            ; y1n (signed, first)
        move    #>$5B6DB6,y0             ; K1 = 5/7 (>=0, second)
        mpy     y1,y0,a
        move    x:(r7+$1),b              ; y2_old -- still needed, not yet
                                          ; overwritten
        add     b,a
        sub     x0,a                     ; a = y3
        move    a,x:(r7+$21)             ; Y3_L

; ---- y2n = y2_old - k3_mag*y3  (subtract: true k3 is negative) ----
        move    x:(r7+$21),y1            ; y3 (signed, first)
        move    x:(r7+$5),y0             ; k3_mag (>=0, second)
        mpy     y1,y0,a
        move    x:(r7+$1),b              ; y2_old, last use
        sub     a,b                      ; b = y2n
        move    b,x:(r7+$22)             ; Y2N_L
        move    b,x:(r7+$1)              ; commit new y2

; ---- y1_sat = smoothstep(y1n), INLINED (see routine header above) ----
        move    x:(r7+$20),a             ; Yn = y1n
        move    x:(r7+$6),y0             ; DRIVE16 (>=0, second)
        move    a,y1                     ; Yn (signed, first)
        mpy     y1,y0,a                  ; a = P = Yn*DRIVE16 (v/64)
        move    a,b                      ; b = P (stash)
        move    #>$FE0000,x0             ; LO = -1/64 true, exact
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a                  ; a = max(P,LO) = M
        move    a,b
        move    #>$01FFFF,x0             ; HI = +1/64 true (Q123_MAX/64)
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b                      ; b = min(M,HI) = P clamped
        move    b,a
        asl     #$6,a,a                  ; a = v (true smoothstep input)
        move    a,x1                     ; x1 = v
        abs     a                        ; a = |v|
        move    a,x0                     ; x0 = |v|
        move    a,y1                     ; y1 = |v| (second copy, for square)
        mpy     x0,y1,a                  ; a = v^2 (both >=0 -- safe)
        move    a,y0                     ; y0 = v^2 (>=0, second)
        mpy     x1,y0,a                  ; a = v^3 (x1=v signed first)
        move    a,b
        asr     #$1,b,b                  ; b = v^3*0.5
        move    x1,a                     ; a = v
        move    a,x0
        asr     #$1,a,a                  ; a = v*0.5
        add     x0,a                     ; a = v*1.5
        sub     b,a                      ; a = v*1.5 - v^3*0.5 = smoothstep
        move    a,x:(r7+$23)             ; Y1SAT_L

; ---- y2_sat = smoothstep(y2n), INLINED, identical shape as above ----
        move    x:(r7+$22),a             ; Yn = y2n
        move    x:(r7+$6),y0
        move    a,y1
        mpy     y1,y0,a
        move    a,b
        move    #>$FE0000,x0
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a
        move    a,b
        move    #>$01FFFF,x0
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b
        move    b,a
        asl     #$6,a,a
        move    a,x1
        abs     a
        move    a,x0
        move    a,y1
        mpy     x0,y1,a
        move    a,y0
        mpy     x1,y0,a
        move    a,b
        asr     #$1,b,b
        move    x1,a
        move    a,x0
        asr     #$1,a,a
        add     x0,a
        sub     b,a
        move    a,x:(r7+$24)             ; Y2SAT_L

; ---- y3 clamped to true +/-1 for the output path only, INLINED (the
; UNCLIPPED y3 already did its job updating y2n above -- matches the JSFX
; exactly, which clips a separate local `y3` copy, never `this.y3` itself).
; Branchless (A+B+/-|A-B|)/2 max-then-min identity, fattener.asm's own
; proven d8-clamp sequence. ----
        move    x:(r7+$21),a             ; y3 (true/4 scale)
        move    a,b                      ; b = y3 (stash)
        move    #>$E00000,x0             ; LO = -1 true, /4 scale, exact
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a                  ; a = max(y3,LO) = M
        move    a,b
        move    #>$1FFFFF,x0             ; HI = +1 true, /4 scale (Q123_MAX/4)
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b                      ; b = min(M,HI) = y3 clamped (/4)
        move    b,a
        asl     #$2,a,a                  ; a = true clipped y3

; ---- g3 term: -(y3_clipped * |g3|), magnitude mpy + subtract for sign ----
        move    a,y1                     ; y3_clipped (signed, first)
        move    #>$4A23CF,y0             ; G3_MAG_HALF = |g3|/2 (>=0, second)
        mpy     y1,y0,a
        asl     #$1,a,a                  ; undo the /2
        move    a,x:(r7+$25)             ; G3TERM_L (magnitude)

; ---- combine: raw_sum = y1_sat + y2_sat - g3term ----
        move    x:(r7+$23),a
        move    x:(r7+$24),b
        add     b,a
        move    x:(r7+$25),b
        sub     b,a                      ; raw_sum

; ---- trim: (raw_sum/4) * trim_k, undo the /4 ----
        asr     #$2,a,a                  ; combine-stage headroom
        move    a,y1                     ; raw_sum/4 (signed, first)
        move    x:(r7+$7),y0             ; trim_k (>=0, second)
        mpy     y1,y0,a
        asl     #$2,a,a                  ; a = y_out (true; caller's store
                                          ; saturates naturally if this is
                                          ; still past +/-1)
        rts

tapehead_r:
; Mechanical copy of tapehead_l with state offsets moved to the R-channel
; bank ($2/$3 instead of $0/$1) and scratch moved to $30.. instead of
; $20.. -- same reasoning as Inflator's onechan_r. Same full inlining as
; tapehead_l, for the same reason (see tapehead_l's own header above).
        asr     #$2,a,a
        move    a,x0

        move    x:(r7+$3),y1
        move    x:(r7+$4),y0
        mpy     y1,y0,a
        move    x:(r7+$2),b
        add     b,a
        move    a,x:(r7+$30)
        move    a,x:(r7+$2)

        move    x:(r7+$30),y1
        move    #>$5B6DB6,y0
        mpy     y1,y0,a
        move    x:(r7+$3),b
        add     b,a
        sub     x0,a
        move    a,x:(r7+$31)

        move    x:(r7+$31),y1
        move    x:(r7+$5),y0
        mpy     y1,y0,a
        move    x:(r7+$3),b
        sub     a,b
        move    b,x:(r7+$32)
        move    b,x:(r7+$3)

; y1_sat = smoothstep(y1n), inlined
        move    x:(r7+$30),a
        move    x:(r7+$6),y0
        move    a,y1
        mpy     y1,y0,a
        move    a,b
        move    #>$FE0000,x0
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a
        move    a,b
        move    #>$01FFFF,x0
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b
        move    b,a
        asl     #$6,a,a
        move    a,x1
        abs     a
        move    a,x0
        move    a,y1
        mpy     x0,y1,a
        move    a,y0
        mpy     x1,y0,a
        move    a,b
        asr     #$1,b,b
        move    x1,a
        move    a,x0
        asr     #$1,a,a
        add     x0,a
        sub     b,a
        move    a,x:(r7+$33)

; y2_sat = smoothstep(y2n), inlined
        move    x:(r7+$32),a
        move    x:(r7+$6),y0
        move    a,y1
        mpy     y1,y0,a
        move    a,b
        move    #>$FE0000,x0
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a
        move    a,b
        move    #>$01FFFF,x0
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b
        move    b,a
        asl     #$6,a,a
        move    a,x1
        abs     a
        move    a,x0
        move    a,y1
        mpy     x0,y1,a
        move    a,y0
        mpy     x1,y0,a
        move    a,b
        asr     #$1,b,b
        move    x1,a
        move    a,x0
        asr     #$1,a,a
        add     x0,a
        sub     b,a
        move    a,x:(r7+$34)

; y3 output-clamp, inlined
        move    x:(r7+$31),a
        move    a,b
        move    #>$E00000,x0
        sub     x0,a
        abs     a
        add     b,a
        add     x0,a
        asr     #$1,a,a
        move    a,b
        move    #>$1FFFFF,x0
        sub     x0,a
        abs     a
        add     x0,b
        sub     a,b
        move    b,a
        asl     #$2,a,a

        move    a,y1
        move    #>$4A23CF,y0
        mpy     y1,y0,a
        asl     #$1,a,a
        move    a,x:(r7+$35)

        move    x:(r7+$33),a
        move    x:(r7+$34),b
        add     b,a
        move    x:(r7+$35),b
        sub     b,a

        asr     #$2,a,a
        move    a,y1
        move    x:(r7+$7),y0
        mpy     y1,y0,a
        asl     #$2,a,a
        rts

; ---------------------------------------------------------------------------
; poly6 -- shared degree-5 polynomial evaluator: p0 + p1*x + p2*x^2 + ... +
; p5*x^5. Caller stages x^1..x^5 at r7+$8..$c and p0..p5 at r7+$d..$12
; before calling. Returns the RAW (un-shifted) accumulator sum in `a` -- the
; caller applies its own undo-shift afterward (DRIVE16 needs none; TRIM_K
; needs asl #2). Copied from fattener.asm's own poly6 (same staging shape,
; same y1=variable-first/y0=coefficient-second mpy order) rather than
; reinvented -- see header note 2 for the one open question this carries
; over (a negative coefficient in the y0 slot, unconfirmed against mpysu).
; ---------------------------------------------------------------------------
poly6:
        move    x:(r7+$d),a              ; c0 (seed -- p0*x^0, loaded
                                          ; directly, not multiplied)

        move    x:(r7+$8),y1             ; x^1 (variable, first)
        move    x:(r7+$e),y0             ; c1 (coefficient, second)
        mpy     y1,y0,b
        add     b,a

        move    x:(r7+$9),y1             ; x^2
        move    x:(r7+$f),y0             ; c2
        mpy     y1,y0,b
        add     b,a

        move    x:(r7+$a),y1             ; x^3
        move    x:(r7+$10),y0            ; c3
        mpy     y1,y0,b
        add     b,a

        move    x:(r7+$b),y1             ; x^4
        move    x:(r7+$11),y0            ; c4
        mpy     y1,y0,b
        add     b,a

        move    x:(r7+$c),y1             ; x^5
        move    x:(r7+$12),y0            ; c5
        mpy     y1,y0,b
        add     b,a
        rts
