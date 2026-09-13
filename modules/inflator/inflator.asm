; ---------------------------------------------------------------------------
; INFLATOR v2 -- octabam module, repoints id 0x05 (SPATIALIZER) dispatch.
; Port of RCInflator 2 (Oxford Edition), band-split waveshaper/saturator.
;
; STATUS: second draft. Every formula below is numerically validated against
; the float JSFX reference in sim_inflator.py (quantization error ~1e-6 to
; 3.7e-5 across the full parameter range tested, including the previously-
; overflowing hot-signal case) -- NOT yet run through tools/harness/dsp_host,
; which is the actual bar for "correct" on this project. Treat this as "the
; arithmetic is right," not "this assembles and dispatches right."
;
; WHAT CHANGED FROM v1, AND WHY (read this before the code):
;
; 1. INPUT trim is back to its original 0.5x..1.49x range. v1 capped it to
;    0..1x to chase an overflow that turned out to have nothing to do with
;    input trim at all -- confirmed by testing pre=1.0 (no trim, no boost)
;    and getting the same overflow. Capping would have shipped a real
;    limitation to work around a bug that was somewhere else entirely.
;
; 2. The one-pole filter (both bands) is REWRITTEN. The original form,
;    x_new = i + c*(x-i), needs (x-i) as a multiply operand -- and that
;    difference can reach +/-2 (input and stale filter state at opposite
;    full-scale extremes is a real condition on fast material through a
;    slow filter, not a contrived edge case; this is exactly what
;    overflowed). Distributing the multiply avoids ever forming it:
;        x_new = i + c*(x-i) = (1-c)*i + c*x
;    Both products are individually safe (|c|,|1-c| < 1, |i|,|x| < 1).
;    This is also, conveniently, the EXACT SAME computation the high-band
;    filter already needed (r = (1-c)*i + c*x) -- so both bands now share
;    one `onepole` subroutine, called with different coefficients/state,
;    with the caller deciding whether to keep the result (low band) or
;    subtract it from x (high band).
;
; 3. The waveshaper's A coefficient (range [1.0, 1.99] at CURVE's extremes)
;    and the mid-band gain (~1.11) both exceed 1 and can't be direct mpy
;    operands (which must be 24-bit register values). Both decompose
;    around 1 instead of needing a headroom-and-undo-shift:
;        A*y    = y + (A-1)*y        -- A-1 in [0, 0.99], a safe operand
;        M*gain = M + (gain-1)*M     -- gain-1 ~= 0.11, safe
;    One extra mpy and add each, no rescaling, no register-lifetime trap.
;
; CLIP is still fixed at +/-1 true for v1 (the y<2 waveshaper branch and
; CLIP=off stay out of scope, same reasoning as before) -- that decision
; wasn't the bug and doesn't need revisiting.
;
; KNOWN, ACCEPTED BEHAVIOR: band-split mode, even at default settings, can
; push the summed output past +/-1 by a substantial margin (measured up to
; ~0.48 over, i.e. ~3.6 dB, at CURVE's hot extreme with full-scale input --
; see sim_inflator.py's output). The float original tolerates this because
; it has headroom above 0 dBFS; fixed-point hardware doesn't, and the final
; store to x:(r0) will hard-limit it. This is the same reason the original
; plugin has an OUTPUT knob -- an "inflator" is supposed to add loudness,
; and on real hardware that loudness has to be managed the same way it
; would on a mixer, by pulling OUTPUT back rather than expecting free
; headroom. Not treating this as a bug; flagging it so it isn't mistaken
; for one on first listen.
;
; Audio I/O, params (page 1, 6 slots), and state layout are unchanged from
; the first draft -- see that file's header for the full parameter table.
; State layout note: r7+$0/$1 = L low/high filter i; r7+$2/$3 = R low/high
; filter i; r7+$4.. = per-call scratch (pre/post/wet/dry/curve terms plus
; the L/H/M/y-power staging below) -- generously memory-scratched rather
; than register-juggled, on purpose: this effect has cycle budget to spare
; (DSP.md's own budget table puts a waveshaper in the "comfortably
; affordable" class), and every register-reuse shortcut in the first draft
; is what produced a bug. Correctness over cycles until this is verified.
; ---------------------------------------------------------------------------

; Constants inlined directly at every use site below -- this assembler
; rejects `equ` (see the "InvalidInstruction" errors it gave on every equ
; line AND every #>NAME reference to one; guessed syntax, wrong, fixed by
; not needing named constants at all rather than guessing a second time).
; Kept here as a lookup table since the raw hex means nothing on its own:
;   $0226E0  = c_low  (240 Hz @ 44.1k), Q1.23
;   $7BB241  = Km1_low  = 2*(1-c_low)-1, Q1.23 -- onepole's headroom-safe
;              state coefficient (see onepole's own header for why this
;              replaced the original "1-c_low"/$7DD920)
;   $12D89C  = c_high (2400 Hz @ 44.1k), Q1.23
;   $5A4EC7  = Km1_high = 2*(1-c_high)-1, Q1.23 -- same, high band
;   $0E11D4  = gain - 1 (~0.10992), Q1.23 -- safe operand
;   $7352E0  = 1/gain, Q1.23
; All from gen_inflator_constants.py's math (Km1 added after the state-
; overflow bug was found; not yet folded into that script itself -- if the
; band-split frequencies ever change, recompute Km1 = 2*(1-c)-1 by hand
; from the script's own c_low/c_high output, or extend the script).

; ---------------------------------------------------------------------------
; CYCLES_FORWARD_BRANCHES -- the SPLIT/plain choice is two forward skips in
; the sample loop (13 Sep 2026); nothing in the loop branches backward.

init:
        move    #0,a
        move    a,x:(r7+$0)
        move    a,x:(r7+$1)
        move    a,x:(r7+$2)
        move    a,x:(r7+$3)
        rts

; ---------------------------------------------------------------------------
proc:
; ---- precompute (once per call): pre/post/wet/dry/curve-derived A-1/B/C/D -
; NO SHIFT NEEDED to turn a page-1 knob into a Q1.23 fraction: value<<16,
; read straight as a Q1.23 number, already IS value/128 -- confirmed by
; delay_server.asm's own comment on PING ("knob<<16 already IS value/128
; in that format, no mpy needed"). An earlier draft of this file applied
; an extra asr #$9 here, misremembered from BusDelay's TIME knob (a
; DIFFERENT trick, for building a sample count, not a Q1.23 fraction) --
; that divided every knob here by an extra 512, which is why the first
; render measured 324k non-zero samples at a peak that printed as 0.000:
; real signal, just ~1/512 the level it should have been (and squared,
; ~1/262144, once both pre and post carried the same error).
        move    x:(r6+$0),a             ; INPUT
                                        ; pre = 0.5 + value/128 ranges up to
                                        ; ~1.49 -- CANNOT be stored as a plain
                                        ; Q1.23 value (only representable up
                                        ; to just under 1.0; the bit pattern
                                        ; for exactly 1.0 is actually -1.0
                                        ; two's complement). So store just
                                        ; the safe part (delta = value/128,
                                        ; always < 1) and let the two halves
                                        ; of the multiply (x*0.5 and x*delta)
                                        ; combine in the accumulator at the
                                        ; point of use instead -- same
                                        ; decompose-around-a-safe-pivot idea
                                        ; as A-1 and gain-1 elsewhere in
                                        ; this file, applied here because I
                                        ; missed it here the first time.
        move    a,x:(r7+$4)             ; delta = value/128 (0 .. ~0.992)

        move    x:(r6+$3),a             ; OUTPUT
        move    a,x:(r7+$5)             ; post = 0 .. ~0.99

        move    x:(r6+$1),a             ; EFFECT
        move    a,x:(r7+$6)             ; wet
        move    a,x0
        move    #>$7fffff,b
        sub     x0,b
        move    b,x:(r7+$7)             ; dry = 1 - wet

        move    x:(r6+$2),a             ; CURVE
        move    #>$400000,x0
        sub     x0,a                    ; recentre -- (value-64)<<16 read as
                                        ; Q1.23 IS (value-64)/128 = curve_frac
                                        ; directly, same no-shift fact as above
        move    a,x:(r7+$8)             ; keep raw curve_frac (used for B, C)

; A-1 = curve_frac + 0.5  (since A = curve_frac + 1.5)
        move    #>$400000,x0            ; 0.5
        add     x0,a
        move    a,x:(r7+$13)            ; A-1, guaranteed in [0, 0.99]

; B = -2*curve_frac
        move    x:(r7+$8),a
        asl     #$1,a,a
        move    a,x0
        move    #0,a
        sub     x0,a
        move    a,x:(r7+$14)            ; B

; C = curve_frac - 0.5
        move    x:(r7+$8),a
        move    #>$400000,x0
        sub     x0,a
        move    a,x:(r7+$15)            ; C

; D = 0.0625 - 0.25*curve_frac + 0.25*curve_frac^2
; (kept as a direct small computation -- every term stays well under 1,
; no decomposition needed)
        move    x:(r7+$8),a
        move    a,x0
        move    a,x1
        mpy     x0,x1,a                 ; curve_frac^2
        move    #>$200000,y0            ; 0.25
        move    a,x0
        mpy     x0,y0,b                 ; 0.25*curve_frac^2
        move    x:(r7+$8),x0            ; curve_frac
        mpy     x0,y0,a                 ; 0.25*curve_frac
        move    a,x0
        move    b,a
        sub     x0,a                    ; 0.25cf^2 - 0.25cf
        move    #>$080000,x0            ; 0.0625
        add     x0,a
        move    a,x:(r7+$16)            ; D

; SPLIT is page-2 slot 9 (13 Sep 2026: a select may not sit on page 1), the
; SELECT field of the word slot 8 shares: bits 8-15 of r6+$d. Only zero /
; non-zero matters below, so the field is kept as it lands. `and` leaves A2
; stale, so the value goes through a1 -> x0 -> a before it is stored.
        move    x:(r6+$d),a             ; SPLIT select (companion of slot 8)
        and     #>$ff00,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$a)

; ---- sample loop -----------------------------------------------------------
        move    #>$ffffff,m0
        move    #>$1,n0
        do      n7,>inflend

        move    x:(r0),a
; ---- L, inlined (13 Sep 2026): the cycle pricer prices a bsr callee only if
; it is straight-line, and these carried the SPLIT branch; the split/plain
; choice is now two FORWARD skips in the loop body (CYCLES_FORWARD_BRANCHES)
; x' = x*pre = x*0.5 + x*delta -- x*0.5 is a plain shift (no multiply, no
; overflow risk since |x| <= 1 already), x*delta is a safe multiply (delta
; < 1, x <= 1 in magnitude, product < 1). Only their SUM can exceed +/-1,
; and only transiently in the accumulator -- it's stored to x:(r7+$20) via
; the LIMITING move, which is the actual v1 CLIP=on clamp point, not a
; separate step.
        move    a,x1                    ; x1 = raw x, kept for both terms
        move    a,b
        asr     #$1,b,b                 ; b = x*0.5
        move    x:(r7+$4),y1            ; delta
        mpy     x1,y1,a                 ; a = x*delta
        add     b,a                     ; a = x*0.5 + x*delta = x*pre
        move    a,x:(r7+$20)             ; store (LIMITING clamps to +/-1 --
                                        ; that's the v1 CLIP behavior)

        move    x:(r7+$a),b             ; SPLIT
        tst     b
        beq     nosplit_l

        move    x:(r7+$20),x0           ; x'
        move    #>$0226E0,x1
        move    #>$7BB241,y0
        move    x:(r7+$0),y1            ; old lpf_i
        bsr     onepole                 ; -> a = L, b = new lpf_i
        move    b,x:(r7+$0)
        move    a,x:(r7+$21)            ; L

        move    x:(r7+$20),x0           ; x'
        move    #>$12D89C,x1
        move    #>$5A4EC7,y0
        move    x:(r7+$1),y1            ; old hpf_i
        bsr     onepole                 ; -> a = r, b = new hpf_i
        move    b,x:(r7+$1)
        move    a,x0                    ; r
        move    x:(r7+$20),a            ; x'
        sub     x0,a                    ; H = x' - r
        move    a,x:(r7+$22)            ; H

        move    x:(r7+$20),a            ; x'
        move    x:(r7+$21),x0
        sub     x0,a                    ; x' - L
        move    x:(r7+$22),x0
        sub     x0,a                    ; x' - L - H = M
        move    a,x:(r7+$23)            ; M

        move    x:(r7+$21),a
        bsr     waveshape
        move    a,x:(r7+$21)            ; shape(L)

        move    x:(r7+$23),a            ; M
        move    #>$0E11D4,x0
        move    a,y1
        mpy     y1,x0,a                 ; (gain-1)*M -- M (variable, crosses
                                        ; zero) FIRST, gain-1 (fixed) SECOND
        add     y1,a                    ; + M => M*gain
        bsr     waveshape                ; shape(M*gain)
        move    #>$7352E0,x0
        move    a,y1
        mpy     y1,x0,a                 ; * 1/gain -- shaped result
                                        ; (variable) FIRST, 1/gain SECOND
        move    a,x:(r7+$23)            ; mid-band term

        move    x:(r7+$22),a
        bsr     waveshape
        move    a,x:(r7+$22)            ; shape(H)

        move    x:(r7+$21),a
        move    x:(r7+$23),x0
        add     x0,a
        move    x:(r7+$22),x0
        add     x0,a                    ; sum of three (LIMITING on the
        move    x:(r7+$a),b             ; SPLIT again: the compare above was
        tst     b                       ; clobbered by the work in between
        bne     lpost                   ; split: skip the plain shape (forward)

nosplit_l:
        move    x:(r7+$20),a
        bsr     waveshape

lpost:
        move    x:(r7+$5),y1            ; post
        move    a,x0
        mpy     x0,y1,a
        move    a,x:(r0)

        move    x:(r0+n0),a
; ---- R, inlined: the mechanical copy ($2/$3 state, $30.. scratch)
; Mechanical copy of onechan_l with the state/scratch offsets moved to the
; R-channel banks ($2/$3 filter state instead of $0/$1, $30.. scratch
; instead of $20..) -- same reasoning, same instructions, nothing else
; changed. Written out in full rather than shared via a parameterized
; routine for the same reason given in the v1 header: no confirmed way to
; do address-register arithmetic in this ABI without guessing, so explicit
; duplication is the safer choice until onechan_l is confirmed correct and
; there's a second copy to generalize from.
        move    a,x1                    ; x1 = raw x
        move    a,b
        asr     #$1,b,b                 ; b = x*0.5
        move    x:(r7+$4),y1            ; delta (shared precompute -- same
                                        ; INPUT knob for both channels)
        mpy     x1,y1,a                 ; a = x*delta
        add     b,a                     ; a = x*pre
        move    a,x:(r7+$30)

        move    x:(r7+$a),b             ; SPLIT
        tst     b
        beq     nosplit_r

        move    x:(r7+$30),x0           ; x'
        move    #>$0226E0,x1
        move    #>$7BB241,y0
        move    x:(r7+$2),y1            ; old lpf_i (R)
        bsr     onepole
        move    b,x:(r7+$2)
        move    a,x:(r7+$31)            ; L

        move    x:(r7+$30),x0           ; x'
        move    #>$12D89C,x1
        move    #>$5A4EC7,y0
        move    x:(r7+$3),y1            ; old hpf_i (R)
        bsr     onepole
        move    b,x:(r7+$3)
        move    a,x0                    ; r
        move    x:(r7+$30),a            ; x'
        sub     x0,a                    ; H = x' - r
        move    a,x:(r7+$32)            ; H

        move    x:(r7+$30),a            ; x'
        move    x:(r7+$31),x0
        sub     x0,a
        move    x:(r7+$32),x0
        sub     x0,a                    ; M
        move    a,x:(r7+$33)

        move    x:(r7+$31),a
        bsr     waveshape
        move    a,x:(r7+$31)            ; shape(L)

        move    x:(r7+$33),a            ; M
        move    #>$0E11D4,x0
        move    a,y1
        mpy     y1,x0,a                 ; M (variable) FIRST, gain-1 SECOND
        add     y1,a                    ; M*gain
        bsr     waveshape
        move    #>$7352E0,x0
        move    a,y1
        mpy     y1,x0,a                 ; shaped result FIRST, 1/gain SECOND
        move    a,x:(r7+$33)            ; mid-band term

        move    x:(r7+$32),a
        bsr     waveshape
        move    a,x:(r7+$32)            ; shape(H)

        move    x:(r7+$31),a
        move    x:(r7+$33),x0
        add     x0,a
        move    x:(r7+$32),x0
        add     x0,a
        move    x:(r7+$a),b             ; SPLIT again: the compare above was
        tst     b                       ; clobbered by the work in between
        bne     rpost                   ; split: skip the plain shape (forward)

nosplit_r:
        move    x:(r7+$30),a
        bsr     waveshape

rpost:
        move    x:(r7+$5),y1            ; post
        move    a,x0
        mpy     x0,y1,a
        move    a,x:(r0+n0)

        move    #>$2,n0
        move    (r0)+n0
        move    #>$1,n0
inflend:
        rts

; ---------------------------------------------------------------------------
; onechan_l / onechan_r: process one channel end to end. Identical shape,
; different filter-state offsets ($0/$1 vs $2/$3) and scratch bank ($20..
; for L, $30.. for R) so they can't clobber each other if this ever gets
; reworked to interleave rather than run sequentially.
; In: a = raw input sample. Out: a = processed sample (pre-post-trim
; already applied; CLIP is always-on in v1, true +/-1 range throughout).
; ---------------------------------------------------------------------------


; ---------------------------------------------------------------------------
; REBUILT to fix a real bug: the persistent state "i" (a TPT integrator
; term, not the filter's output) is NOT naturally bounded to +/-1 the way
; a stable filter's OUTPUT is -- and storing it in a plain Q1.23 register
; with no headroom meant it periodically overflowed and got silently
; saturated to exactly the ceiling, corrupting the filter's memory for
; every sample afterward. Confirmed directly: tapped L and watched it snap
; to exactly +1.000000 every ~30-120 samples, then decay smoothly until
; the next snap -- the unmistakable signature of state saturation, not a
; one-off glitch. Dry-mode testing could never have caught this: M is
; DEFINED as x'-L-H, so L+M+H=x' is a tautology regardless of whether L
; and H individually hold correct values.
;
; Fix: the persistent state is now stored HALVED (I = true_i/2), giving
; one full bit of headroom (true_i can range to +/-2 before ever
; saturating again). The compensating x2 is folded into the coefficient
; itself so no extra runtime shift is needed:
;   v = 2*(1-c)*I + c*x = (1 + Km1)*I + c*x,  where Km1 = 2*(1-c) - 1
;   new_I = v - I   (this alone replaces "new_i = 2v - i" -- no explicit
;                    doubling anywhere, verified algebraically and by a
;                    5000-iteration random-input numerical check against
;                    the original recursion before this was written, not
;                    just derived on paper)
; In:  x0 = x, x1 = c, y0 = Km1, y1 = I (old, HALVED state)
; Out: a = v (filter output, full scale -- unchanged for callers), b = new_I
;      (HALVED -- callers store this back exactly as before, no change
;      needed there beyond passing Km1 instead of the old 1-c constant)
onepole:
        mpy     y1,y0,a                 ; I*Km1 -- I (can be small/variable)
                                        ; FIRST, Km1 (fixed, never tiny)
                                        ; SECOND. Confirmed by direct test:
                                        ; a small-magnitude value only
                                        ; produces the correct sign when
                                        ; it's the mpy's FIRST operand --
                                        ; the SAME value in the SECOND slot
                                        ; silently clears the sign bit
                                        ; while leaving the magnitude bits
                                        ; correct (e.g. $FFCC29 -> $7FCC29).
                                        ; This was the actual root cause of
                                        ; the periodic +1.000000 snaps.
        add     y1,a                    ; + I = (1+Km1)*I = 2*(1-c)*I
        mpy     x0,x1,b                 ; x*c -- x (variable, small near
                                        ; zero-crossings) FIRST, c (fixed)
                                        ; SECOND, same reasoning
        add     b,a                     ; v = 2*(1-c)*I + c*x
        move    a,x0                    ; stash v
        sub     y1,a                    ; new_I = v - I
        move    a,b                     ; new_I -> b (caller stores it)
        move    x0,a                    ; v -> a (the return value)
        rts

; ---------------------------------------------------------------------------
; waveshape: v1, CLIP always on, so x is already +/-1 true and y=|x|<=1 --
; the JSFX's y<2 branch is unreachable here and not implemented.
;   s = A*y + B*y^2 + C*y^3 - D*(y^2 - 2*y^3 + y^4)
;     = [y + (A-1)*y] + B*y^2 + C*y^3 - D*y^2 + 2D*y^3 - D*y^4
; A*y uses the A-1 decomposition (header note 3). y^2/y^3/y^4 are each
; individually <= 1 (y <= 1), so they're safe to store as ordinary Q1.23
; values with no decomposition needed -- only the RUNNING SUM (which can
; legitimately exceed 1 mid-polynomial before other terms bring it back
; down) stays in the accumulator until the final result.
; In: a = x. Out: a = wet*sign(x)*s + dry*x.
; ---------------------------------------------------------------------------
waveshape:
        move    a,x:(r7+$24)            ; stash signed x (sign + dry term)
        abs     a                       ; y = |x|
        move    a,x0                    ; x0 = y

        move    x0,x1
        mpy     x0,x1,a                 ; y^2
        move    a,x:(r7+$25)

        move    x:(r7+$25),x1           ; y^2
        mpy     x0,x1,a                 ; y^3
        move    a,x:(r7+$26)

        move    x:(r7+$25),x1
        mpy     x1,x1,a                 ; y^4
        move    a,x:(r7+$27)

; s = y + (A-1)*y  [running sum starts here, in a]
        move    x:(r7+$13),y0           ; A-1
        mpy     x0,y0,a                 ; (A-1)*y
        add     x0,a                    ; + y

; + B*y^2
        move    x:(r7+$25),x1
        move    x:(r7+$14),y0           ; B -- can be negative (B=-2*curve_frac)
        mpy     y0,x1,b                 ; B FIRST (can be small/negative),
                                        ; y^2 (always >=0) SECOND
        add     b,a

; + C*y^3
        move    x:(r7+$26),x1
        move    x:(r7+$15),y0           ; C -- always negative, shrinks
                                        ; toward ~0 at CURVE's hot extreme
        mpy     y0,x1,b                 ; C FIRST, y^3 SECOND
        add     b,a

; - D*y^2
        move    x:(r7+$25),x1
        move    x:(r7+$16),y0           ; D
        mpy     x1,y0,b
        sub     b,a

; + 2*D*y^3   (2*(D*y^3), computed as one mpy then a shift, not a redundant
; second D*y^3 mpy)
        move    x:(r7+$26),x1
        mpy     x1,y0,b                 ; D*y^3
        asl     #$1,b,b                 ; 2*D*y^3
        add     b,a

; - D*y^4
        move    x:(r7+$27),x1
        mpy     x1,y0,b                 ; D*y^4
        sub     b,a

; a now holds s (the shaped magnitude) -- apply wet, sign, dry
        move    x:(r7+$6),y0            ; wet
        move    a,x0
        mpy     x0,y0,a                 ; s*wet
        move    a,x:(r7+$28)            ; stash s*wet -- needed either way

; the sign select, BRANCHLESS (13 Sep 2026): this routine is a bsr callee of
; the sample loop and the cycle pricer requires it straight-line. Tcc takes a
; REGISTER source, so the negated value goes through x1, and nothing but
; moves sits between the tst and the tmi (the flag-clobber trap).
        move    x:(r7+$28),a            ; s*wet
        move    a,b
        neg     b                       ; -(s*wet)
        move    b,x1                    ; clean register for the Tcc
        move    x:(r7+$24),x0           ; signed x, for the sign test
        move    x0,b                    ; tst needs an accumulator operand
        tst     b
        tmi     x1,a                    ; x < 0: a = -(s*wet); else s*wet

        move    x:(r7+$7),y0            ; dry
        move    x:(r7+$24),x0           ; signed x
        mpy     x0,y0,b                 ; x*dry
        add     b,a                     ; s*wet*sign + x*dry
        rts
