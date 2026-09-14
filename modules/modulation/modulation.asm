; ---------------------------------------------------------------------------
; MODULATION -- one modulated line, seven modes, FX1 only.
;
; Insert contract (modules/ripple/ripple_svf.asm). NOT a bus client since
; 14 Sep 2026: the stations lost their sends in the one-aux rig (7 Sep) and
; the bus bookkeeping this carried -- the split-aware frame offset, the
; rotation latch, a registration that could never register (its level was
; a hard 0) and two sends multiplying by that 0 -- went with them, as
; Spectrum's did on 12 Sep. Harness(bus_client=False).
;
; ---- FX1 ONLY, ENFORCED HERE ---------------------------------------------
; The base comes from the host's bump allocator, read in INIT and only there
; (docs/firmware/DSP.md section 10: X:0x213 is per-instance during init and garbage in
; proc). FX1 slots are 0x1000 0x1c00 0x2800 0x3400; FX2 slots are 0x4000 and
; up, and every one of those is a server's ground -- BusVerb's tank on core
; 0, BusDelay's line on tracks 3-4. So a base >= 0x4000 sets a flag that
; sends proc down the DRY path, which writes NOTHING to Y. That promise is
; what Claims(fx1_only=True) declares to the ledger, and tools/
; verify_modulation.py is what proves it.
;
; Two lines of 1,024 words, L at base+0 and R at base+1024: 23 ms each, out
; of the 3,072 an FX1 slot gives. The read offset is MASKED (& $3ff), not the
; address, so nothing depends on where the allocator put us.
;
; ---- the modes -----------------------------------------------------------
; ONE sample loop, chosen once per block (the Ripple pattern, which
; cycle_count prices as "worst of N mode loops"):
;
;   LINE  CHOR FLNG COMB -- one modulated tap with feedback. The modes
;         differ only in per-block coefficients: centre delay, sweep depth
;         and feedback. Vibrato is CHOR at MIX 127 (the dry left out).
;
; (13 Sep 2026: PHSR, TREM, VIB and PAN retired -- Sam. The phaser was the
; pricer's dearest station loop (464 cycles, two allpass chains a sample);
; tremolo and auto-pan are the OT's own LFO on AMP VOL / BAL; vibrato is a
; MIX setting. The freed cycles and words fund Spectrum.)
;
; Every mode outputs the WET only; MIX does the blending, so MIX 0 is an
; exact passthrough in every mode and 127 is the wet outright.
;
; ---- the LFO -------------------------------------------------------------
; Per SAMPLE, not per block: at a 15-sample block a per-block LFO steps at
; 2.9 kHz, which a chorus hears as zipper. Two shaped copies, L and its
; WID-offset partner, from one phase accumulator. TRI is the basis; SIN is
; the parabola 2t - t|t| blended in; SAW is the phase itself, 2t - 1,
; blended in the same way (3 Sep 2026: it FELL THROUGH TO TRI until then --
; four labels, three shapes); SQR is TRI multiplied up and clamped by
; a limiting store. All three are one code path with per-block weights.
;
; ---- r7 slots -------------------------------------------------------------
;   ⚠️ EVERY SLOT THE SAMPLE LOOPS TOUCH IS BELOW $40: an r7 displacement past
;   63 assembles to the two-word long form (it cost the Spectrum station 30
;   words before that was found). ⚠️ Until 14 Sep 2026 dsp_asm emitted the
;   two-word form for EVERY displacement, sub-$40 included; the one-word
;   form is the assembler's since then, and only since then.
;   $19 line base (per instance)     $1a dry flag: 1 = FX2 slot or MIX 0
;   $1b write phase (PERSISTENT)     $1c LFO phase (PERSISTENT)
;   $1d lfo L this sample            $1e lfo R this sample
;   $20 m (MIX)
;   $21 centre delay, Q11.12         $22 sweep depth, Q11.12
;   $23 feedback                     $24 tone coefficient
;   $25 WID phase offset             $26 LFO increment per sample
;   $27 sin blend weight             $28 square gain / 8
;   $18 saw blend weight             $17 saw this sample (shape scratch)
;   $2a scratch (shape)
;   $32/$33 feedback tone state L/R      (PERSISTENT)
;   $3c tap L  $3d tap R  $3e scratch  $3f scratch
;
; Every mpy is `mpy x0,y1` (the audited-signed encoding). Every Tcc reads the ONE compare above it with nothing but moves
; between (the flag-clobber trap). No label here is a PREFIX of another --
; dsp_asm resolves by prefix, and `ch_sat` inside `ch_satr` cost the
; Character station an afternoon.
; ---------------------------------------------------------------------------

init:
; ---- the allocator base, and the FX1/FX2 decision ------------------------
; Nimbus Lite's idiom (modules/nimbuslite/nimbus_lite.asm): X:0x213 points at
; this instance's entry in the base table. Valid HERE and nowhere else.
        move    x:>$213,r4
        move    #>$ffffff,m4
        move    x:(r4),x0
        move    x0,x:(r7+$19)           ; the line base
; sub/tst rather than cmp: the cmp-encodes-as-max family (CLAUDE.md).
        move    x0,a
        move    #>$4000,x0
        sub     x0,a                    ; base - 0x4000
        clr     b                       ; b = 0 BEFORE the tst (the flag trap)
        move    #>$1,x0
        tst     a
        tpl     x0,b                    ; base >= 0x4000: an FX2 slot
        move    b,x:(r7+$1a)
        tst     b
        bne     monoclr                 ; FX2: never touch the buffer at all
; ---- clear both lines, once, at instantiation ----------------------------
        move    x:(r7+$19),a
        move    a,r5
        move    #>$ffffff,m5
        clr     a
        do      #2048,>moclrz
        move    a,y:(r5)+
moclrz:
        nop
monoclr:
        clr     a
        move    a,x:(r7+$1b)            ; write phase
        move    a,x:(r7+$1c)            ; LFO phase
        move    a,x:(r7+$32)            ; feedback tone states
        move    a,x:(r7+$33)
        rts

proc:
; (the bus section -- split-aware frame offset, the rotation latch, the
; registration and the r1/r2 accumulator pointers -- left with the sends,
; 14 Sep 2026: the station has carried no send since the one-aux rig of
; 7 Sep, the registration compared a hard 0 so it never registered, and the
; ~156 words and ~19 cycles a sample it cost bought nothing. Spectrum shed
; its copy on 12 Sep. The station is no longer a bus client:
; Harness(bus_client=False).)

; ===========================================================================
; PER-BLOCK KNOB DECODE
; ===========================================================================
; MIX
        move    x:(r6+$3),x0
        move    x0,x:(r7+$20)
; LFO increment: RATE^2 * $2600 + $30 per sample (~0.05 .. ~8 Hz)
        move    x:(r6+$0),x0
        move    x:(r6+$0),y1
        mpy     x0,y1,a
        move    a,x0
; ⚠️ $600, NOT $2600: the increment is a fraction of 2^23 per SAMPLE, so
; freq = inc * 44100 / 2^23. $2600 topped the knob out at 51 Hz -- audio
; rate, not an LFO, and a chorus swept that fast is just noise (measured
; 3 Sep 2026). $600 gives 0.06 Hz at the bottom and 7.9 Hz at the top.
        move    #>$600,y1
        mpy     x0,y1,a
        add     #>$10,a
        move    a,x:(r7+$26)
; WID -> the right channel's LFO phase offset, 0 .. half a cycle
        move    x:(r6+$e),a
        and     #>$7f0000,a
        move    a1,x0
        move    x0,a
        asr     #$1,a,a                 ; 0 .. ~0.5 of a cycle
        move    a,x:(r7+$25)
; SHPE (slot 9 select of r6+$d): the sin blend, the saw blend, the square gain
        clr     a
        move    a,x:(r7+$27)            ; sin weight 0
        move    a,x:(r7+$18)            ; saw weight 0
        move    #$10,x0                 ; square gain / 8 = 1/8, i.e. gain 1 (short: bits 23-16)
        move    x0,x:(r7+$28)
        move    x:(r6+$d),a
        and     #>$ff00,a
        move    a1,x0
        move    x0,a
        asl     #$8,a,a
        move    #>$10000,x0
        cmp     x0,a
        beq     mo_shsin
        move    #>$20000,x0
        cmp     x0,a
        beq     mo_shsqr
        move    #>$30000,x0
        cmp     x0,a
        beq     mo_shsaw
        bra     mo_shdone               ; TRI, and anything unexpected
mo_shsin:
        move    #>$7fffff,x0            ; the parabola, all of it
        move    x0,x:(r7+$27)
        bra     mo_shdone
mo_shsqr:
        move    #>$7fffff,x0            ; gain 8, clamped by a limiting store
        move    x0,x:(r7+$28)
        bra     mo_shdone
mo_shsaw:
        move    #>$7fffff,x0            ; the saw, all of it
        move    x0,x:(r7+$18)
mo_shdone:
; TONE -> the one-pole coefficient inside the feedback path
        move    x:(r6+$d),a
        and     #>$7f0000,a
        move    a1,x0
        move    x0,a
        move    a,x0
        move    #$7c,y1                 ; (short immediate: bits 23-16)
        mpy     x0,y1,a
        add     #>$040000,a
        move    a,x:(r7+$24)
; DLY -> the centre delay in Q11.12 samples, ~0.2 .. 23 ms (8 .. 1000)
        move    x:(r6+$c),a
        and     #>$7f0000,a
        move    a1,x0
        move    x0,a
        move    a,x0
; ⚠️ NO SHIFT. $3e0000 IS 992*4096, so the product already lands in Q11.12:
; mpy(DLY/128, 992*4096/2^23) leaves (992*DLY/128)*4096 in a1. The `asr #11`
; that used to be here divided it by 2,048, which pinned every line mode at
; its 8-sample floor -- an 8-sample chorus, measured as an impulse coming
; back 7 samples late instead of 473 (3 Sep 2026).
        move    #$3e,y1                 ; 992 samples, pre-scaled to Q11.12 (short: bits 23-16)
        mpy     x0,y1,a
        add     #>$8000,a               ; + 8 samples of floor
        move    a,x:(r7+$21)
; DPTH -> the sweep depth in Q11.12 samples
        move    x:(r6+$1),x0
        move    #$1e,y1                 ; 480 samples, pre-scaled to Q11.12 (short: bits 23-16)
        mpy     x0,y1,a                 ; (no shift -- see the note above)
        move    a,x:(r7+$22)
; FDBK -> the feedback amount (RES in PHSR: the chain's resonance)
        move    x:(r6+$2),x0
        move    x0,x:(r7+$23)
; ---- MODE (slot 7 select of r6+$c): the per-mode overrides of centre, ----
; depth and feedback. CHOR is the fall-through -- and so is any stored value
; past 2 (an old part's PHSR/TREM/VIB/PAN byte, 3..6): only 1 (FLNG) and 2
; (COMB) match, everything else is CHOR.
        move    x:(r6+$c),a
        and     #>$ff00,a
        move    a1,x0
        move    x0,a
        asl     #$8,a,a
        move    #>$10000,x0
        cmp     x0,a
        beq     mo_mflng
        move    #>$20000,x0
        cmp     x0,a
        beq     mo_mcomb
; CHOR: a 10 ms centre, a gentle sweep, no feedback
        move    #>$28000,x0             ; 40 samples ~ 0.9 ms floor
        move    x:(r7+$21),a
        add     x0,a
        move    a,x:(r7+$21)
        clr     a
        move    a,x:(r7+$23)            ; no feedback
        bra     mo_mdone
mo_mflng:
        move    #>$4000,x0              ; 4 samples: the jet lives short
        move    x0,x:(r7+$21)
        move    x:(r7+$22),a
        asr     #$2,a,a                 ; a quarter of the sweep
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$22)
        bra     mo_mdone
mo_mcomb:
        move    x:(r7+$22),a
        asr     #$4,a,a                 ; barely swept: it is a resonator
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$22)
mo_mdone:
; ---- keep the read inside the 1,024-word line (12 Sep 2026) ---------------
; centre + depth must stay below 1,016 samples and centre - depth above 8:
; CHOR's 40-sample floor put DLY 127 at 1,032 (masked to 8: the impulse
; came back 0.18 ms late instead of 23), and a deep sweep at a long centre
; wrapped the same way. Centre is capped at 1,000; depth at the smaller of
; (centre - 8) and (1,015 - centre). Q11.12 throughout; cmp + one Tcc each.
        move    x:(r7+$21),a            ; centre
        move    #>$3e8000,x0            ; 1,000 samples
        cmp     x0,a
        tgt     x0,a
        move    a,x:(r7+$21)
        move    a,b
        move    #>$8000,x0              ; 8 samples
        sub     x0,b                    ; centre - 8
        move    b,x1
        move    #>$3f7000,b             ; 1,015 samples
        sub     a,b                     ; 1,015 - centre
        move    x:(r7+$22),a            ; depth
        cmp     x1,a
        tgt     x1,a                    ; depth <= centre - 8
        move    b,x1
        cmp     x1,a                    ; nothing between: the flag trap
        tgt     x1,a                    ; depth <= 1,015 - centre
        move    a,x:(r7+$22)
; ---- the dry path: an FX2 slot, or MIX at zero ---------------------------
        move    x:(r7+$1a),a            ; the FX2 flag from init
        tst     a
        bne     mo_dry
        move    x:(r7+$20),a            ; MIX
        tst     a
        beq     mo_dry
; ===========================================================================
; THE LINE LOOP -- CHOR, FLNG, COMB (the one engine since 13 Sep 2026)
; ===========================================================================
        move    #$1,n0                  ; (short immediate, stock's own form)
        do      n7,>molinz
        bsr     moshap                  ; both LFOs, into $1d and $1e
; ---- advance the write phase --------------------------------------------
        move    x:(r7+$1b),a
        add     #>$1,a
        and     #>$3ff,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$1b)
; ---- L: the modulated tap ------------------------------------------------
        move    x:(r7+$1d),x0           ; lfo L
        move    x:(r7+$22),y1           ; depth, Q11.12
        mpy     x0,y1,a                 ; the sweep, Q11.12 signed
        move    x:(r7+$21),x0           ; centre
        add     x0,a
        move    a,x:(r7+$3e)            ; park the total
        asr     #$c,a,a                 ; integer samples
        move    a1,x0
        move    x:(r7+$1b),a            ; the write phase
        sub     x0,a                    ; ... minus the delay
        and     #>$3ff,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$3f)            ; park the read phase
        move    x:(r7+$19),x0           ; the line base
        add     x0,a
        move    a,r5
        move    #>$ffffff,m5
        move    y:(r5),a                ; t0
        move    a,x:(r7+$3c)
        move    x:(r7+$3f),a
        add     #>$3ff,a                ; the neighbour, one sample OLDER (-1
        and     #>$3ff,a                ; mod 1024): a delay of i + f blends
                                        ; toward i + 1. Blending toward the
                                        ; NEWER sample made the delay i - f,
                                        ; a two-sample jump at every integer
                                        ; crossing of the sweep -- a crackle
                                        ; on hats, invisible on a 440 Hz sine
                                        ; (ear + fix 12 Sep 2026)
        move    a1,x0
        move    x0,a
        move    x:(r7+$19),x0
        add     x0,a
        move    a,r5
        move    y:(r5),a                ; t1
        move    x:(r7+$3c),x0
        sub     x0,a                    ; t1 - t0
        move    a1,x0
        move    x:(r7+$3e),a            ; the total again, for its fraction
        and     #>$fff,a
        asl     #$b,a,a                 ; -> Q23
        move    a1,y1
        mpy     x0,y1,a                 ; frac * (t1 - t0)
        move    x:(r7+$3c),x0
        add     x0,a                    ; the interpolated tap
        move    a,x:(r7+$3c)            ; wet L
; ---- L: the feedback write ----------------------------------------------
; the one-pole INSIDE the feedback: s += c*(tap - s). It accumulated c*tap
; instead until 3 Sep 2026, which walks the state to the rail rather than
; damping the loop.
        move    x:(r7+$3c),a            ; the tap
        move    x:(r7+$32),b            ; the state
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$24),y1           ; the coefficient
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a                     ; s'
        move    a,x:(r7+$32)
        move    a,x0
        move    x:(r7+$23),y1           ; feedback
        mpy     x0,y1,a
        move    x:(r0),x0
        add     x0,a                    ; input + feedback
        move    a,x:(r7+$3e)            ; LIMITING store: the loop cannot rail
        move    x:(r7+$1b),a
        move    x:(r7+$19),x0
        add     x0,a
        move    a,r5
        move    x:(r7+$3e),a
        move    a,y:(r5)                ; write the line
; ---- R: the same, on the second line ------------------------------------
        move    x:(r7+$1e),x0           ; lfo R
        move    x:(r7+$22),y1
        mpy     x0,y1,a
        move    x:(r7+$21),x0
        add     x0,a
        move    a,x:(r7+$3e)
        asr     #$c,a,a
        move    a1,x0
        move    x:(r7+$1b),a
        sub     x0,a
        and     #>$3ff,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$3f)
        move    x:(r7+$19),x0
        add     x0,a
        add     #>$400,a                ; the right line, 1,024 words up
        move    a,r5
        move    y:(r5),a
        move    a,x:(r7+$3d)
        move    x:(r7+$3f),a
        add     #>$3ff,a                ; the older neighbour (as L)
        and     #>$3ff,a
        move    a1,x0
        move    x0,a
        move    x:(r7+$19),x0
        add     x0,a
        add     #>$400,a
        move    a,r5
        move    y:(r5),a
        move    x:(r7+$3d),x0
        sub     x0,a
        move    a1,x0
        move    x:(r7+$3e),a
        and     #>$fff,a
        asl     #$b,a,a
        move    a1,y1
        mpy     x0,y1,a
        move    x:(r7+$3d),x0
        add     x0,a
        move    a,x:(r7+$3d)            ; wet R
        move    x:(r7+$3d),a
        move    x:(r7+$33),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$24),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$33)
        move    a,x0
        move    x:(r7+$23),y1
        mpy     x0,y1,a
        move    x:(r0+n0),x0
        add     x0,a
        move    a,x:(r7+$3e)
        move    x:(r7+$1b),a
        move    x:(r7+$19),x0
        add     x0,a
        add     #>$400,a
        move    a,r5
        move    x:(r7+$3e),a
        move    a,y:(r5)
        bsr     momixs                  ; MIX from $3c/$3d
        move    (r0)+n0                 ; the frame advance: n0 is 1 for the
        move    (r0)+n0                 ; whole loop, so two steps, no reload
molinz:
        nop
        rts

; ===========================================================================
; THE DRY PATH: an FX2 slot, or MIX at zero. Frames untouched -- with no
; sends there is nothing to do at all (the loop that multiplied the mono by
; two zero levels and added 0 to both accumulators went 14 Sep 2026).
; ===========================================================================
mo_dry:
        rts

; ---------------------------------------------------------------------------
; moshap -- the two LFOs for this sample, into $1d (L) and $1e (R).
; The shaper is INLINED twice rather than called: cycle_count requires a bsr
; callee to be straight-line, and a callee that itself calls is refused --
; which costs the module its price, and an unpriced module cannot ship.
; The phase advances once; the right channel reads it WID further round.
; TRI is the basis, SIN is the parabola 2t - t|t| blended in by $27, and SQR
; is the whole thing multiplied by 8 and clamped by a limiting store -- so
; all three shapes are one code path with two per-block coefficients.
; ---------------------------------------------------------------------------
moshap:
        move    x:(r7+$1c),a            ; the phase
        move    x:(r7+$26),x0
        add     x0,a
        and     #>$7fffff,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$1c)
        move    #$40,x0                 ; 0.5 (short immediate: bits 23-16)
        move    a,b
        sub     x0,b                    ; phase - 0.5 ...
        asl     #$1,b,b                 ; ... x2: the saw, -1 .. 1
        move    b,x:(r7+$17)            ; LIMITING store, for the blend below
        sub     x0,a                    ; phase - 0.5
        abs     a                       ; 0 .. 0.5
        asl     #$2,a,a                 ; 0 .. 2, in the guard bits
        move    #>$7fffff,x0
        sub     x0,a                    ; the triangle, -1 .. 1
        move    a,x:(r7+$2a)            ; LIMITING store, so |tri| <= 1
        move    x:(r7+$2a),x1           ; tri
        move    x1,a
        abs     a
        move    a,y1                    ; |tri|
        move    x1,x0
        mpy     x0,y1,a                 ; tri * |tri|
        neg     a
        move    x1,b
        asl     #$1,b,b                 ; 2 * tri
        add     b,a                     ; the parabola, -1 .. 1
        move    x1,x0
        sub     x0,a                    ; parabola - tri
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$27),y1           ; the sin blend
        mpy     x0,y1,a
        asl     #$1,a,a
        add     x1,a                    ; tri + w*(parabola - tri)
        move    a,x1                    ; the wave so far (|.| <= 1)
        move    x:(r7+$17),a            ; the saw
        sub     x1,a                    ; saw - wave
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$18),y1           ; the saw blend
        mpy     x0,y1,a
        asl     #$1,a,a
        add     x1,a                    ; wave + w*(saw - wave)
        move    a,x0
        move    x:(r7+$28),y1           ; the square gain / 8
        mpy     x0,y1,a
        asl     #$3,a,a
        move    a,x:(r7+$2a)            ; LIMITING store: this IS the square
        move    x:(r7+$2a),a
        move    a,x:(r7+$1d)            ; lfo L
        move    x:(r7+$1c),a
        move    x:(r7+$25),x0           ; ... WID further round
        add     x0,a
        and     #>$7fffff,a
        move    a1,x0
        move    x0,a
        move    #$40,x0                 ; 0.5 (short immediate: bits 23-16)
        move    a,b
        sub     x0,b                    ; phase - 0.5 ...
        asl     #$1,b,b                 ; ... x2: the saw, -1 .. 1
        move    b,x:(r7+$17)            ; LIMITING store, for the blend below
        sub     x0,a                    ; phase - 0.5
        abs     a                       ; 0 .. 0.5
        asl     #$2,a,a                 ; 0 .. 2, in the guard bits
        move    #>$7fffff,x0
        sub     x0,a                    ; the triangle, -1 .. 1
        move    a,x:(r7+$2a)            ; LIMITING store, so |tri| <= 1
        move    x:(r7+$2a),x1           ; tri
        move    x1,a
        abs     a
        move    a,y1                    ; |tri|
        move    x1,x0
        mpy     x0,y1,a                 ; tri * |tri|
        neg     a
        move    x1,b
        asl     #$1,b,b                 ; 2 * tri
        add     b,a                     ; the parabola, -1 .. 1
        move    x1,x0
        sub     x0,a                    ; parabola - tri
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$27),y1           ; the sin blend
        mpy     x0,y1,a
        asl     #$1,a,a
        add     x1,a                    ; tri + w*(parabola - tri)
        move    a,x1                    ; the wave so far (|.| <= 1)
        move    x:(r7+$17),a            ; the saw
        sub     x1,a                    ; saw - wave
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$18),y1           ; the saw blend
        mpy     x0,y1,a
        asl     #$1,a,a
        add     x1,a                    ; wave + w*(saw - wave)
        move    a,x0
        move    x:(r7+$28),y1           ; the square gain / 8
        mpy     x0,y1,a
        asl     #$3,a,a
        move    a,x:(r7+$2a)            ; LIMITING store: this IS the square
        move    x:(r7+$2a),a
        move    a,x:(r7+$1e)            ; lfo R
        rts


; ---------------------------------------------------------------------------
; momixs -- MIX the wet in $3c/$3d against the dry still in the frame and
; write it back. One copy of the mix law (it was shared by three engines
; until 13 Sep 2026; the send tail that followed it -- the processed mono
; times two zero levels into both accumulators -- went 14 Sep 2026).
; ---------------------------------------------------------------------------
momixs:
        move    x:(r7+$3c),a
        move    x:(r0),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$20),y1           ; m
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r0)
        move    x:(r7+$3d),a
        move    x:(r0+n0),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$20),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r0+n0)
        rts
