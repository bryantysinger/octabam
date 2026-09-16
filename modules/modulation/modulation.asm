; ---------------------------------------------------------------------------
; MODULATION -- a modulation pedal: JUNO, DIM, FLNG, COMB, PHSR, each a
; transcription of the source modules/modulation/modulation_ref.py names
; (docs/effects/PORTS.md), proven against that float reference. Three sample
; loops, one chosen per block: LINE (JUNO, DIM and FLNG differ only in five
; per-block mix weights bl bd ff kc kb), PHSR, COMB. Insert contract
; (modules/ripple/ripple_svf.asm). FX1 only: init reads the allocator base
; (X:0x213 -> this instance's entry, valid at init and nowhere else); a base
; >= 0x4000 is an FX2 slot and proc runs the dry path, which writes nothing
; to Y. Two 1,024-word lines (L, R) out of the FX1 slot's 3,072; the read
; offset is masked, not the address. MIX 0 is an exact passthrough; a
; change of MODE clears every state slot.
; ---------------------------------------------------------------------------

init:
; ---- the allocator base, and the FX1/FX2 decision ------------------------
        move    x:>$213,r4
        move    #>$ffffff,m4
        move    x:(r4),x0
        move    x0,x:(r7+$0e)           ; the line base
; sub/tst rather than cmp: the cmp-encodes-as-max family (CLAUDE.md).
        move    x0,a
        move    #>$4000,x0
        sub     x0,a                    ; base - 0x4000
        clr     b                       ; b = 0 BEFORE the tst (the flag trap)
        move    #>$1,x0
        tst     a
        tpl     x0,b                    ; base >= 0x4000: an FX2 slot
        move    b,x:(r7+$0d)
        tst     b
        bne     monoclr                 ; FX2: never touch the buffer at all
; ---- clear both lines, once, at instantiation ----------------------------
        move    x:(r7+$0e),a
        move    a,r5
        move    #>$ffffff,m5
        clr    a
        do      #2048,>moclrz
        move    a,y:(r5)+
moclrz:
        nop
monoclr:
; ---- every persistent slot to zero (verify_dirtystate) -------------------
        clr     a
        move    r7,r5
        move    #>$ffffff,m5
        move    #$11,n5
        move    (r5)+n5                 ; $11 .. $46
        do      #54,>moiclz
        move    a,x:(r5)+
moiclz:
        nop
        rts

; ===========================================================================
proc:
; ===========================================================================
; PER-BLOCK KNOB DECODE
; ===========================================================================
        move    #>$ffffff,m5
; MIX (page-1 slot 5, bottom right on every effect); 127 = 1.0, the wet
; outright (the through-zero null is exact)
        move    x:(r6+$5),a
        move    #>$7f0000,x0
        cmp     x0,a                    ; k - 127
        move    #>$7fffff,x0
        tge     x0,a
        move    a,x:(r7+$00)
; LFO increment: RATE^2 * $780 + $10 per sample (~0.08 .. 10 Hz)
        move    x:(r6+$0),x0
        move    x:(r6+$0),y1
        mpy     x0,y1,a
        move    a,x0
        move    #>$780,y1
        mpy     x0,y1,a
        add     #>$10,a
        move    a,x:(r7+$01)
; WDTH (page-2 slot 8, $d's knob field, bits 16-23) -> the right channel's
; LFO phase offset, 0 .. half a cycle
        move    x:(r6+$d),a             ; a knob word: bit 23 clear, so a2 = 0
        and     #>$7f0000,a             ; ... and stays 0 through the and
        asr     #$1,a,a
        move    a,x:(r7+$06)
; TONE (page-2 slot 7, $c's companion field, bits 8-15) -> the one-pole
; coefficient 0.25 + 0.75 * k/128; 127 = 1.0, an exact bypass (the
; flanger's through-zero null needs the blend and the wet alike). The knob
; word is parked in $46 (COMB's FIR reads it below).
        move    x:(r6+$c),a
        and     #>$7f00,a
        asl     #$8,a,a
        move    a1,x:(r7+$46)           ; TONE << 16
        move    a1,x0
        move    #$60,y1                 ; 0.75 (short immediate: bits 23-16)
        mpy     x0,y1,a
        add     #>$200000,a             ; + 0.25
        move    x:(r7+$46),b
        move    #>$7f0000,x0
        cmp     x0,b                    ; k - 127
        move    #>$7fffff,x0
        tge     x0,a                    ; k >= 127: open
        move    a,x:(r7+$05)
; FDBK (page-1 slot 3) -> bipolar, (k - 64)/64: -1 .. +0.984
        move    x:(r6+$3),a
        sub     #>$400000,a             ; k/128 - 0.5
        asl     #$1,a,a
        move    a,x:(r7+$04)
; DLY (page-1 slot 2) -> the centre delay in Q11.12 samples, 8 .. 1,000
        move    x:(r6+$2),a
        and     #>$7f0000,a
        move    a1,x0                   ; (a knob word, non-negative)
; $3e0000 IS 992*4096, so the product already lands in Q11.12 (no shift)
        move    #$3e,y1                 ; 992 samples, pre-scaled to Q11.12
        mpy     x0,y1,a
        add     #>$8000,a               ; + 8 samples of floor
        move    #>$3e8000,x0            ; 1,000 samples
        cmp     x0,a
        tgt     x0,a
        move    a,x:(r7+$02)
; DPTH -> the sweep depth in Q11.12 samples, clamped so the read stays inside
; the line: <= centre - 8 and <= 1,015 - centre
        move    a,b
        move    #>$8000,x0
        sub     x0,b                    ; centre - 8
        move    b,x1
        move    #>$3f7000,b             ; 1,015 samples
        sub     a,b                     ; 1,015 - centre
        move    x:(r6+$1),x0
        move    #$1e,y1                 ; 480 samples, pre-scaled to Q11.12
        mpy     x0,y1,a
        cmp     x1,a
        tgt     x1,a                    ; depth <= centre - 8
        move    b,x1
        cmp     x1,a                    ; nothing between: the flag trap
        tgt     x1,a                    ; depth <= 1,015 - centre
        move    a,x:(r7+$03)
; the P table base (rewritten by build_bus.py; the literal appears ONCE)
        move    #>$fab1e0,r5
        move    r5,x:(r7+$0f)
; LOFI (page-1 slot 4): the hold length 1 + 64 (k/128)^2
; samples (an integer in $42; 17 at 64, 64 at 127) and the bit mask from the
; 16-word table at P + 132 on k >> 3 ($45); k = 0 is hold 1 and a full
; mask: bit-exact (verify_modulation)
        move    x:(r6+$4),a
        and     #>$7f0000,a
        move    a1,x0
        move    a1,y1
        mpy     x0,y1,a                 ; (k/128)^2, Q23
        asr     #$11,a,a                ; x 64: an integer 0..63
        add     #>$1,a
        move    a1,x:(r7+$42)
        move    x:(r6+$4),a
        and     #>$7f0000,a
        asr     #$13,a,a                ; k >> 3: 0..15
        move    x:(r7+$0f),r5
        move    #$84,n5                 ; 4 x 33 words in front of the masks
        move    (r5)+n5
        move    a1,n5
        move    (r5)+n5
        move    p:(r5),x0
        move    x0,x:(r7+$45)
; ---- MODE (slot 6 select of r6+$c, the knob field) ------------------------
; A change of mode clears every state slot $23..$3c (Spectrum's rule: a
; state that meant something else in the last mode is garbage in this one).
        move    x:(r6+$c),a
        and     #>$ff0000,a
        move    x:(r7+$40),x0           ; the last block's select ($40: above
        move    a1,x:(r7+$40)           ; the loops' slots, per block only)
        sub     x0,a                    ; (a2 = 0: both positive)
        beq     mo_msame
        clr     a
        move    r7,r5
        move    #$23,n5
        move    (r5)+n5
        do      #26,>mo_mclr
        move    a,x:(r5)+
mo_mclr:
        nop
mo_msame:
        move    x:(r7+$40),a
        asr     #$10,a,a
        move    a1,x0
        move    x0,a                    ; the mode, 0..4, clean
        move    a,x:(r7+$0c)
; ---- the dry path: an FX2 slot, or MIX at zero ---------------------------
        move    x:(r7+$0d),a            ; the FX2 flag from init
        tst     a
        bne     mo_dry
        move    x:(r7+$00),a            ; MIX
        tst     a
        beq     mo_dry
; ---- dispatch, once per block ---------------------------------------------
        move    x:(r7+$0c),a
        cmp     #>$1,a
        beq     mo_bdim
        cmp     #>$2,a
        beq     mo_bflng
        cmp     #>$3,a
        beq     mo_bcomb
        cmp     #>$4,a
        beq     mo_bphsr
; JUNO (and any stored value past 4): bl 0, bd 0, ff 1, kc 0, kb 0
        clr     a
        move    #>$7fffff,x0
        move    a,x:(r7+$07)
        move    a,x:(r7+$08)
        move    x0,x:(r7+$09)
        move    a,x:(r7+$0a)
        move    a,x:(r7+$0b)
        bra     mo_line
mo_bdim:
; DIM: bl 0, bd 1, ff 0.25, kc -1, kb 0.5 (OURS: the SDD-320's amounts are
; unpublished; the highpass and the lift's lowpass are one-poles at 200 Hz),
; all x 0.398: the -8 dB trim that levels it with JUNO at the views
        clr     a
        move    a,x:(r7+$07)
        move    #>$32f52d,x0            ; 0.398
        move    x0,x:(r7+$08)
        move    #>$0cbd4b,x0            ; 0.0995
        move    x0,x:(r7+$09)
        move    #>$cd0ad3,x0            ; -0.398
        move    x0,x:(r7+$0a)
        move    #>$197a96,x0            ; 0.199
        move    x0,x:(r7+$0b)
        bra     mo_line
mo_bflng:
; FLNG: bl 0.7071, bd 0, ff -0.7071, kc 0, kb 0 (Dattorro Table 6); bl and
; ff x 0.447, the -7 dB trim (the feedback is FDBK's, untrimmed)
        clr     a
        move    #>$286dc6,x0            ; 0.7071 x 0.447
        move    x0,x:(r7+$07)
        move    a,x:(r7+$08)
        move    #>$d7923a,x0            ; -0.7071 x 0.447
        move    x0,x:(r7+$09)
        move    a,x:(r7+$0a)
        move    a,x:(r7+$0b)
        bra     mo_line

; ===========================================================================
; THE LINE LOOP -- JUNO, DIM, FLNG: two lines, one triangle LFO
;   wet_L = bl*fixed_L + bd*dry_L + ff*LPo(tap_L) + kc*HP(LPo(tap_R)) + kb*LPb(dry_L)
;   line_L <- LPi(dry_L) + fb*tap_L ; R mirrored.
; ===========================================================================
mo_line:
        move    #$1,n0                  ; (short immediate, stock's own form)
        do      n7,>molinz
        bsr     mo_lfo                  ; both triangles, into $19 and $1f
; ---- advance the write phase ----------------------------------------------
        move    x:(r7+$20),a            ; 0..1023, so phase + 1 is 1..1024: a2 = 0
        add     #>$1,a
        and     #>$3ff,a
        move    a1,x:(r7+$20)           ; a1 straight to memory: no limiter
; ---- L: the swept tap ----------------------------------------------------------
        move    x:(r7+$19),x0           ; lfo L
        move    x:(r7+$03),y1           ; depth, Q11.12
        mpy     x0,y1,a                 ; the sweep, Q11.12 signed
        move    x:(r7+$02),x0           ; centre
        add     x0,a
        clr     b
        move    b,y0                    ; line L
        bsr     mo_tap
        move    a,x:(r7+$3d)            ; tap L
; ---- R: the same on the second line ----------------------------------------
        move    x:(r7+$1f),x0           ; lfo R
        move    x:(r7+$03),y1
        mpy     x0,y1,a
        move    x:(r7+$02),x0
        add     x0,a
        move    #>$400,y0               ; line R
        bsr     mo_tap
        move    a,x:(r7+$3e)            ; tap R
; ---- the line writes: LPi(dry) + fb*tap, a LIMITING store ------------------
        move    x:(r0),a                ; dry L
        move    x:(r7+$23),b            ; lpi L
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$05),y1           ; c
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$23)
        move    a,b                     ; (limited)
        move    x:(r7+$3d),x0           ; tap L
        move    x:(r7+$04),y1           ; fb
        mpy     x0,y1,a
        add     b,a
        move    a,x:(r7+$10)            ; LIMITING store: the loop cannot rail
        move    x:(r7+$20),a
        move    x:(r7+$0e),x0
        add     x0,a
        move    a,r5
        move    x:(r7+$10),a
        bsr     mo_lofl
        move    a,y:(r5)                ; write line L
        move    x:(r0+n0),a             ; dry R
        move    x:(r7+$24),b            ; lpi R
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$05),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$24)
        move    a,b
        move    x:(r7+$3e),x0           ; tap R
        move    x:(r7+$04),y1
        mpy     x0,y1,a
        add     b,a
        move    a,x:(r7+$10)
        move    x:(r7+$20),a
        move    x:(r7+$0e),x0
        add     x0,a
        add     #>$400,a
        move    a,r5
        move    x:(r7+$10),a
        bsr     mo_lofr
        move    a,y:(r5)                ; write line R
; ---- LPo on both taps (in place) --------------------------------------------
        move    x:(r7+$3d),a
        move    x:(r7+$25),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$05),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$25)
        move    a,x:(r7+$3d)            ; wo L
        move    x:(r7+$3e),a
        move    x:(r7+$26),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$05),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$26)
        move    a,x:(r7+$3e)            ; wo R
; ---- wet L = bl*fixed_L + bd*dry_L + ff*wo_L + kc*HP_L(wo_R) + kb*LPb_L(dry_L)
        move    x:(r7+$02),a            ; the fixed tap at the centre (read after
        clr     b                       ; this sample's write: a delay >= 8 never
        move    b,y0                    ; sees it)
        bsr     mo_tap
        move    a,x0                    ; fixed L
        move    x:(r7+$07),y1           ; bl
        mpy     x0,y1,a
        move    x:(r0),x0               ; dry L
        move    x:(r7+$08),y1           ; bd
        mac     x0,y1,a
        move    x:(r7+$3d),x0           ; wo L
        move    x:(r7+$09),y1           ; ff
        mac     x0,y1,a
        move    a,x1                    ; the sum so far (limited)
; HP_L(wo_R): s += c200*(x - s); hp = x - s
        move    x:(r7+$3e),a            ; wo R
        move    x:(r7+$27),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    #>$039912,y1            ; c200 = 0.0281
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$27)
        move    x:(r7+$3e),b
        sub     a,b                     ; hp
        move    b,x0
        move    x:(r7+$0a),y1           ; kc
        mpy     x0,y1,a
        add     x1,a
        move    a,x1
; LPb_L(dry_L)
        move    x:(r0),a
        move    x:(r7+$29),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    #>$039912,y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$29)
        move    a,x0
        move    x:(r7+$0b),y1           ; kb
        mpy     x0,y1,a
        add     x1,a
        move    a,x:(r7+$3d)            ; wet L (limited)
; ---- wet R, mirrored ----------------------------------------------------------
        move    x:(r7+$02),a            ; R's fixed tap at the centre
        move    #>$400,y0
        bsr     mo_tap
        move    a,x0                    ; fixed R
        move    x:(r7+$07),y1           ; bl
        mpy     x0,y1,a
        move    x:(r0+n0),x0            ; dry R
        move    x:(r7+$08),y1
        mac     x0,y1,a
        move    x:(r7+$3e),x0           ; wo R
        move    x:(r7+$09),y1
        mac     x0,y1,a
        move    a,x1
; HP_R(wo_L): lpo L's state IS wo L this sample ($3d holds wet L by now)
        move    x:(r7+$25),a            ; wo L
        move    x:(r7+$28),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    #>$039912,y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$28)
        move    x:(r7+$25),b
        sub     a,b
        move    b,x0
        move    x:(r7+$0a),y1
        mpy     x0,y1,a
        add     x1,a
        move    a,x1
        move    x:(r0+n0),a
        move    x:(r7+$2a),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    #>$039912,y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$2a)
        move    a,x0
        move    x:(r7+$0b),y1
        mpy     x0,y1,a
        add     x1,a
        move    a,x:(r7+$3e)            ; wet R
        bsr     momixs                  ; MIX from $3d/$3e
        move    (r0)+n0                 ; the frame advance: n0 is 1 for the
        move    (r0)+n0                 ; whole loop, so two steps, no reload
molinz:
        nop
        rts

; ===========================================================================
; PHSR -- ChowPhaser: the per-block LFO and tables, then the loop
; ===========================================================================
mo_bphsr:
; the LFO advances a block at a time here (15 inc); L and R from the
; parabola; v = DPTH * lfo (-1..1) is the LDR's input
        move    x:(r7+$21),a
        move    x:(r7+$01),x0
        do      #15,>mo_padv
        add     x0,a
mo_padv:
        nop
        and     #>$7fffff,a
        move    a1,x:(r7+$21)
        bsr     mo_para
        move    a,x0
        move    x:(r6+$1),y1            ; DPTH
        mpy     x0,y1,a
        move    a,x:(r7+$19)            ; v L
        move    x:(r7+$21),a
        move    x:(r7+$06),x0
        add     x0,a
        and     #>$7fffff,a
        bsr     mo_para
        move    a,x0
        move    x:(r6+$1),y1
        mpy     x0,y1,a
        move    a,x:(r7+$1f)            ; v R
; L: u = (v + 1)/2 -> the two tables -> the ramps toward them
        move    x:(r7+$19),a
        asr     #$1,a,a
        add     #>$400000,a
        move    a,x:(r7+$10)
        move    #$0,n5                  ; the mod table
        bsr     mo_tab
        move    x:(r7+$11),x0           ; bm run L
        sub     x0,a
        asr     #$4,a,a
        move    a,x:(r7+$12)            ; dbm L
        move    x:(r7+$10),a
        move    #$21,n5                 ; the feedback table
        bsr     mo_tab
        move    x:(r7+$13),x0
        sub     x0,a
        asr     #$4,a,a
        move    a,x:(r7+$14)            ; dbf L
; R
        move    x:(r7+$1f),a
        asr     #$1,a,a
        add     #>$400000,a
        move    a,x:(r7+$10)
        move    #$0,n5
        bsr     mo_tab
        move    x:(r7+$15),x0
        sub     x0,a
        asr     #$4,a,a
        move    a,x:(r7+$16)            ; dbm R
        move    x:(r7+$10),a
        move    #$21,n5
        bsr     mo_tab
        move    x:(r7+$17),x0
        sub     x0,a
        asr     #$4,a,a
        move    a,x:(r7+$18)            ; dbf R
; the feedback, clamped to +-0.95
        move    x:(r7+$04),a
        move    #>$79999a,x0            ; 0.95
        cmp     x0,a
        tgt     x0,a
        move    #>$866666,x0            ; -0.95
        cmp     x0,a
        tlt     x0,a
        move    a,x:(r7+$1a)
; STGS on DLY: the tap weights for 2 / 4 / 6 / 8 stages by quarters. Only one
; is set (0.794, the trim); the loop sums all four (branch-free). $1b w2  $1c w4  $1d w6  $1e w8
        clr     a
        move    a,x:(r7+$1b)
        move    a,x:(r7+$1c)
        move    a,x:(r7+$1d)
        move    a,x:(r7+$1e)
        move    x:(r6+$2),a             ; DLY (page-1 slot 2)
        and    #>$7f0000,a
        asr     #$15,a,a                ; DLY >> 5: 0..3
        move    a1,n5
        move    r7,r5
        move    (r5)+n5
        move    #$1b,n5
        move    (r5)+n5
        move    #>$65ac8c,x0            ; 0.794: the -2 dB trim
        move    x0,x:(r5)
; ---- the loop --------------------------------------------------------------
        move    #$1,n0
        do      n7,>mophsz
; ===== channel L =====
        move    x:(r7+$11),a            ; the ramps
        move    x:(r7+$12),x0
        add     x0,a
        move    a,x:(r7+$11)
        move    x:(r7+$13),a
        move    x:(r7+$14),x0
        add     x0,a
        move    a,x:(r7+$13)
        move    x:(r7+$2f),x0           ; y previous (halved, as the chain runs)
        move    x:(r7+$1a),y1           ; fb
        mpy     x0,y1,a
        move    x:(r0),b
        asr     #$1,b,b
        add     b,a                     ; u = x/2 + fb * yprev: the chain runs at
        move    a,x:(r7+$10)            ; HALF scale (an allpass cascade peaks
        move    x:(r7+$10),a            ; above its input; the stores clamp at 1)
        move    r7,r4
        move    #$2b,n4
        move    (r4)+n4                 ; the feedback stages
        move    x:(r7+$13),y1           ; bf
        bsr     mo_apst
        bsr     mo_apst
        move    a,x:(r7+$2f)            ; the feedback section's output
        move    r7,r4
        move    #$23,n4
        move    (r4)+n4                 ; the mod stages
        move    x:(r7+$11),y1           ; bm
        clr     b
        move    b,x:(r7+$3f)            ; the tap sum
        bsr     mo_apst
        bsr     mo_apst
        move    a,x0
        move    x:(r7+$1b),y1           ; w2
        move    x:(r7+$3f),b
        mac     x0,y1,b
        move    b,x:(r7+$3f)
        move    x:(r7+$11),y1
        move    x0,a
        bsr     mo_apst
        bsr     mo_apst
        move    a,x0
        move    x:(r7+$1c),y1           ; w4
        move    x:(r7+$3f),b
        mac     x0,y1,b
        move    b,x:(r7+$3f)
        move    x:(r7+$11),y1
        move    x0,a
        bsr     mo_apst
        bsr     mo_apst
        move    a,x0
        move    x:(r7+$1d),y1           ; w6
        move    x:(r7+$3f),b
        mac     x0,y1,b
        move    b,x:(r7+$3f)
        move    x:(r7+$11),y1
        move    x0,a
        bsr     mo_apst
        bsr     mo_apst
        move    a,x0
        move    x:(r7+$1e),y1           ; w8
        move    x:(r7+$3f),b
        mac     x0,y1,b
        asl     #$1,b,b                 ; back to full scale
        move    b,x:(r7+$3d)            ; wet L (limited)
        move    x:(r7+$3d),a
        bsr     mo_lofl                 ; no line here: the wet itself
        move    a,x:(r7+$3d)
; ===== channel R =====
        move    x:(r7+$15),a
        move    x:(r7+$16),x0
        add     x0,a
        move    a,x:(r7+$15)
        move    x:(r7+$17),a
        move    x:(r7+$18),x0
        add     x0,a
        move    a,x:(r7+$17)
        move    x:(r7+$30),x0
        move    x:(r7+$1a),y1
        mpy     x0,y1,a
        move    x:(r0+n0),b
        asr     #$1,b,b
        add     b,a
        move    a,x:(r7+$10)
        move    x:(r7+$10),a
        move    r7,r4
        move    #$2d,n4
        move    (r4)+n4
        move    x:(r7+$17),y1
        bsr     mo_apst
        bsr     mo_apst
        move    a,x:(r7+$30)
        move    r7,r4
        move    #$31,n4
        move    (r4)+n4
        move    x:(r7+$15),y1
        clr     b
        move    b,x:(r7+$3f)
        bsr     mo_apst
        bsr     mo_apst
        move    a,x0
        move    x:(r7+$1b),y1
        move    x:(r7+$3f),b
        mac     x0,y1,b
        move    b,x:(r7+$3f)
        move    x:(r7+$15),y1
        move    x0,a
        bsr     mo_apst
        bsr     mo_apst
        move    a,x0
        move    x:(r7+$1c),y1
        move    x:(r7+$3f),b
        mac     x0,y1,b
        move    b,x:(r7+$3f)
        move    x:(r7+$15),y1
        move    x0,a
        bsr     mo_apst
        bsr     mo_apst
        move    a,x0
        move    x:(r7+$1d),y1
        move    x:(r7+$3f),b
        mac     x0,y1,b
        move    b,x:(r7+$3f)
        move    x:(r7+$15),y1
        move    x0,a
        bsr     mo_apst
        bsr     mo_apst
        move    a,x0
        move    x:(r7+$1e),y1
        move    x:(r7+$3f),b
        mac     x0,y1,b
        asl     #$1,b,b
        move    b,x:(r7+$3e)            ; wet R (limited)
        move    x:(r7+$3e),a
        bsr     mo_lofr
        move    a,x:(r7+$3e)
        bsr     momixs
        move    (r0)+n0
        move    (r0)+n0
mophsz:
        nop
        rts

; ===========================================================================
; COMB -- Rings' string loop: the per-block tuning and decay, then the loop
; ===========================================================================
mo_bcomb:
; period from the table on DLY (page-1 slot 2; Q11.12 samples, 1,000 .. 8)
        move    x:(r6+$2),a
        and     #>$7f0000,a
        move    #$42,n5                 ; the period table
        bsr     mo_tab
        move    a,x:(r7+$1e)
; the polarity: FDBK's sign
        move    x:(r7+$04),a
        move    #>$7fffff,x0
        move    #>$800000,x1
        move    x0,b                    ; +1
        tst     a
        tmi     x1,b                    ; -1 when negative
        move    b,x:(r7+$1d)
; the decay: d = |fb|, lf = d(2 - d); T(u) = 2^(-8u): rt60 = 790,272 T(1 - lf)
; samples; q = 1.25 period / rt60 = (period_q * 0.0032394) / T(1 - lf), one
; division (q < 0.41 at every knob, so no clamp); gain = T(q)
        abs     a
        move    a,x0
        move    a,y1
        mpy     x0,y1,b                 ; d^2
        asl     #$1,a,a                 ; 2d
        sub     b,a                     ; lf  (<= 1)
        move    a,x0
        move    #>$7fffff,a
        sub     x0,a                    ; 1 - lf (>= 0)
        move    #$63,n5                 ; the 2^(-8u) table
        bsr     mo_tab
        move    a,x1                    ; T(1 - lf), 1/256 .. 1
        move    x:(r7+$1e),x0
        move    #>$006a27,y1            ; 0.0032394
        mpy     x0,y1,a
        move    a,x0
        move    x0,a                    ; a clean load: a0 = 0 for the divide
        move    x1,x0
        andi    #$fe,ccr                ; carry clear
        rep     #$18
        div     x0,a                    ; 24 quotient bits land in a0
        move    a0,x0
        move    x0,a
        move    #$63,n5
        bsr     mo_tab
        move    a,x:(r7+$1a)            ; the gain per pass
; the FIR: h0 = (1 + b)/2, h1 = (1 - b)/4, b = TONE/128 (parked in $46)
        move    x:(r7+$46),a
        asr     #$1,a,a
        add     #>$400000,a
        move    a,x:(r7+$1b)
        move    x:(r7+$46),a
        asr     #$2,a,a
        neg     a
        add     #>$200000,a
        move    a,x:(r7+$1c)
; ---- the loop --------------------------------------------------------------
        move    #$1,n0
        do      n7,>mocmbz
        move    x:(r7+$20),a
        add     #>$1,a
        and     #>$3ff,a
        move    a1,x:(r7+$20)
; ===== channel L =====
        move    x:(r7+$1e),a
        sub     #>$1000,a               ; period - 1 (the FIR's own delay)
        clr     b
        move    b,y0
        bsr     mo_herm
        move    a,x0
        move    x:(r7+$1d),y1           ; the polarity
        mpy     x0,y1,a
        move    x:(r0),x0
        add     x0,a                    ; s = +-read + x
        move    a,x:(r7+$10)
        move    x:(r7+$10),a            ; (limited)
        move    x:(r7+$3a),x0           ; x2
        add     x0,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$1c),y1           ; h1
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r7+$39),x0           ; x1
        move    x:(r7+$1b),y1           ; h0
        mac     x0,y1,a
        move    a,x:(r7+$3f)
        move    x:(r7+$39),x0           ; x2 <- x1, x1 <- s
        move    x0,x:(r7+$3a)
        move    x:(r7+$10),x0
        move    x0,x:(r7+$39)
        move    x:(r7+$3f),x0
        move    x:(r7+$1a),y1           ; gain
        mpy     x0,y1,a
        bsr     mo_lofl
        move    a,x:(r7+$3d)            ; wet L = the sample written
        move    x:(r7+$20),a
        move    x:(r7+$0e),x0
        add     x0,a
        move    a,r5
        move    x:(r7+$3d),a
        move    a,y:(r5)
; ===== channel R =====
        move    x:(r7+$1e),a
        sub     #>$1000,a
        move    #>$400,y0
        bsr     mo_herm
        move    a,x0
        move    x:(r7+$1d),y1
        mpy     x0,y1,a
        move    x:(r0+n0),x0
        add     x0,a
        move    a,x:(r7+$10)
        move    x:(r7+$10),a
        move    x:(r7+$3c),x0
        add     x0,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$1c),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r7+$3b),x0
        move    x:(r7+$1b),y1
        mac     x0,y1,a
        move    a,x:(r7+$3f)
        move    x:(r7+$3b),x0
        move    x0,x:(r7+$3c)
        move    x:(r7+$10),x0
        move    x0,x:(r7+$3b)
        move    x:(r7+$3f),x0
        move    x:(r7+$1a),y1
        mpy     x0,y1,a
        bsr     mo_lofr
        move    a,x:(r7+$3e)            ; wet R
        move    x:(r7+$20),a
        move    x:(r7+$0e),x0
        add     x0,a
        add     #>$400,a
        move    a,r5
        move    x:(r7+$3e),a
        move    a,y:(r5)
; the -12 dB output trim, after the line writes so the ring is untouched
        move    x:(r7+$3d),x0
        move    #>$2026f3,y1            ; 0.251
        mpy     x0,y1,a
        move    a,x:(r7+$3d)
        move    x:(r7+$3e),x0
        mpy     x0,y1,a
        move    a,x:(r7+$3e)
        bsr     momixs
        move    (r0)+n0
        move    (r0)+n0
mocmbz:
        nop
        rts

; ===========================================================================
; THE DRY PATH: an FX2 slot, or MIX at zero. Frames untouched.
; ===========================================================================
mo_dry:
        rts

; ---------------------------------------------------------------------------
; mo_lfo -- the two triangles for this sample into $19 (L) and $1f (R). The
; phase advances once; the right channel reads it WID further round.
; tri = 4 |phase - 0.5| - 1: 1 at 0, -1 at 0.5. Straight-line.
; ---------------------------------------------------------------------------
mo_lfo:
        move    x:(r7+$21),a
        move    x:(r7+$01),x0
        add     x0,a                    ; phase <= $7fffff + inc <= $790: no carry
        and     #>$7fffff,a             ; into a2, which stays 0 through the and
        move    a1,x:(r7+$21)
        move    #$40,x0                 ; 0.5 (short immediate: bits 23-16)
        sub     x0,a
        abs     a                       ; 0 .. 0.5
        asl     #$2,a,a                 ; 0 .. 2, in the guard bits
        move    #>$7fffff,x0
        sub     x0,a                    ; -1 .. 1
        move    a,x:(r7+$19)            ; LIMITING store: lfo L
        move    x:(r7+$21),a
        move    x:(r7+$06),x0
        add     x0,a                    ; (< 2^24: a2 = 0 through the and)
        and     #>$7fffff,a
        move    #$40,x0
        sub     x0,a
        abs     a
        asl     #$2,a,a
        move    #>$7fffff,x0
        sub     x0,a
        move    a,x:(r7+$1f)            ; lfo R
        rts

; ---------------------------------------------------------------------------
; mo_para -- a = a 0..1 phase -> a = the parabola 2t - t|t| of its triangle,
; -1..1 (the station's sine). Uses x0 x1 y1 b and $3f. Straight-line.
; ---------------------------------------------------------------------------
mo_para:
        move    #$40,x0
        sub     x0,a
        abs     a
        asl     #$2,a,a
        move    #>$7fffff,x0
        sub     x0,a
        move    a,x:(r7+$3f)            ; LIMITING: t
        move    x:(r7+$3f),x1
        move    x1,a
        abs     a
        move    a,y1                    ; |t|
        move    x1,x0
        mpy     x0,y1,a                 ; t|t|
        neg     a
        move    x1,b
        asl     #$1,b,b                 ; 2t
        add     b,a
        rts

; ---------------------------------------------------------------------------
; mo_tap -- a = the delay in Q11.12 (8 .. 1,015), y0 = the line offset (0 or
; $400) -> a = the tap, the fraction blended toward the OLDER neighbour (a
; delay of i + f between the samples at i and i + 1; blending toward the
; newer one made it i - f and clicked at every integer crossing -- 12 Sep
; 2026). Uses x0 x1 y1 b r5 and $3f. Straight-line. AGU settle: r5 is
; written at least two instructions before it addresses.
; ---------------------------------------------------------------------------
mo_tap:
        move    a,x:(r7+$3f)            ; the total
        asr     #$c,a,a
        move    a1,x1                   ; i
        move    x:(r7+$20),a            ; the write phase
        sub     x1,a
        and     #>$3ff,a                ; (a2 may be stale: a1 is what is read)
        move    a1,x0
        move    x:(r7+$0e),a
        add     x0,a
        add     y0,a
        move    a,r5                    ; -> sample i
        move    x0,a
        add     #>$3ff,a                ; i + 1, mod 1024 (positive throughout)
        and     #>$3ff,a
        move    a1,x0
        move    x:(r7+$0e),a
        add     x0,a
        add     y0,a
        move    y:(r5),x1               ; t0
        move    a,r5                    ; -> sample i + 1
        move    x:(r7+$3f),a
        and     #>$fff,a
        asl     #$b,a,a                 ; the fraction, Q23
        move    a1,y1
        move    y:(r5),a                ; t1
        sub     x1,a                    ; t1 - t0
        move    a,x0
        mpy     x0,y1,a                 ; f (t1 - t0)
        add     x1,a
        rts

; ---------------------------------------------------------------------------
; mo_herm -- a = the delay in Q11.12 (>= 4), y0 = the line offset -> a = the
; 4-point Hermite read (stmlib's ReadHermite: xm1 one sample NEWER than i,
; x1 and x2 older), everything scaled by 1/16 so no intermediate leaves +-1:
;   c = (x1 - xm1)/2 ; v = x0 - x1 ; w = c + v ; a = w + v + (x2 - x0)/2 ;
;   b = w + a ; out = (((a f) - b) f + c) f + x0
; Uses x0 x1 y1 b r3 r5 and $10 $23..$2a. Straight-line.
; ---------------------------------------------------------------------------
mo_herm:
        move    a,x:(r7+$3f)
        asr     #$c,a,a
        move    a1,x1                   ; i
        move    x:(r7+$20),a
        sub     x1,a
        add     #>$1,a                  ; i - 1: xm1
        and     #>$3ff,a
        move    a1,x0
        move    x:(r7+$0e),a
        add     x0,a
        add     y0,a
        move    a,r5
        move    x:(r7+$20),a
        sub     x1,a                    ; i: x0
        and     #>$3ff,a
        move    a1,x0
        move    x:(r7+$0e),a
        add     x0,a
        add     y0,a
        move    a,r3
        move    y:(r5),b                ; xm1
        move    b,x:(r7+$23)
        move    x:(r7+$20),a
        sub     x1,a
        add     #>$3ff,a                ; i + 1: x1
        and     #>$3ff,a
        move    a1,x0
        move    x:(r7+$0e),a
        add     x0,a
        add     y0,a
        move    y:(r3),b                ; x0
        move    a,r5
        move    b,x:(r7+$24)
        move    x:(r7+$20),a
        sub     x1,a
        add     #>$3fe,a                ; i + 2: x2
        and     #>$3ff,a
        move    a1,x0
        move    x:(r7+$0e),a
        add     x0,a
        add     y0,a
        move    y:(r5),b                ; x1
        move    a,r3
        move    b,x:(r7+$25)
        move    x:(r7+$3f),a
        and     #>$fff,a
        asl     #$b,a,a
        move    a1,x:(r7+$27)           ; f, Q23
        move    y:(r3),b                ; x2
        move    b,x:(r7+$26)
; the polynomial, /16
        move    x:(r7+$25),a            ; x1
        move    x:(r7+$23),x0           ; xm1
        sub     x0,a
        asr     #$5,a,a                 ; c/16
        move    a,x:(r7+$28)
        move    x:(r7+$24),b            ; x0
        move    x:(r7+$25),x0
        sub     x0,b                    ; v
        asr     #$4,b,b                 ; v/16
        add     b,a                     ; w/16
        move    a,x:(r7+$29)
        add     b,a                     ; w + v
        move    x:(r7+$26),b            ; x2
        move    x:(r7+$24),x0
        sub     x0,b
        asr     #$5,b,b                 ; (x2 - x0)/32
        add     b,a                     ; a/16
        move    a,x:(r7+$2a)
        move    x:(r7+$29),b
        add     b,a                     ; b/16 = (w + a)/16
        move    a,x1
        move    x:(r7+$2a),x0
        move    x:(r7+$27),y1           ; f
        mpy     x0,y1,a                 ; a f /16
        sub     x1,a                    ; - b/16
        move    a,x0
        mpy     x0,y1,a                 ; (..) f
        move    x:(r7+$28),x0
        add     x0,a                    ; + c/16
        move    a,x0
        mpy     x0,y1,a                 ; (..) f
        asl     #$4,a,a                 ; x 16
        move    x:(r7+$24),x0
        add     x0,a                    ; + x0
        rts

; ---------------------------------------------------------------------------
; mo_apst -- one first-order allpass stage: a = x, y1 = b0, r4 -> its state;
; y = b0 x + z ; z' = b0 y - x ; returns a = y (limited), r4 advanced.
; Uses x0 b and $10. Straight-line.
; ---------------------------------------------------------------------------
mo_apst:
        move    a,x0                    ; x (limited)
        mpy     x0,y1,a                 ; b0 x
        move    x:(r4),b
        add     b,a                     ; y
        move    a,x:(r7+$10)            ; LIMITING
        move    x0,b                    ; x
        move    x:(r7+$10),x0           ; y
        mpy     x0,y1,a                 ; b0 y
        sub     b,a                     ; - x
        move    a,x:(r4)+               ; z' (limited), next stage
        move    x:(r7+$10),a            ; y
        rts

; ---------------------------------------------------------------------------
; mo_tab -- a = u (0..1, Q23), n5 = the table's offset -> a = T(u), the
; 33-word table read at idx = u >> 18 and interpolated on the 18 bits under
; it (Spectrum's read). Per block only. Uses x0 x1 y0 y1 b r5 n5.
; ---------------------------------------------------------------------------
mo_tab:
        move    x:(r7+$0f),r5           ; the P table base
        move    a,x1
        asr     #$12,a,a                ; idx
        move    (r5)+n5                 ; + the table's offset
        move    a1,n5
        move    x1,a
        and     #>$3ffff,a
        asl     #$5,a,a                 ; frac, Q23
        move    (r5)+n5                 ; + idx
        move    a,x0
        move    p:(r5)+,y0              ; T[idx]
        move    p:(r5),b                ; T[idx + 1]
        move    y0,a
        sub     a,b                     ; the difference (either sign)
        move    b,y1
        mpy     x0,y1,a
        add     y0,a
        rts

; ---------------------------------------------------------------------------
; mo_lofl / mo_lofr -- LOFI: the value in a held and masked. One counter
; ($41) for both channels: L advances it and latches ($43) on the compare,
; R latches ($44) on the counter reading 0. The mask keeps bit 23, so a2
; stays consistent through the and and the store does not saturate.
; Applied at the LINE WRITE in the line modes and COMB (the line is clocked
; coarse and the taps read through the stairs; COMB's ring recirculates it)
; and on the wet in PHSR, which has no line.
; ---------------------------------------------------------------------------
mo_lofl:
        move    a,y0
        move    x:(r7+$41),a
        move    x:(r7+$42),x0
        move    #>$0,x1
        add     #>$1,a
        cmp     x0,a
        tge     x1,a
        move    a1,x:(r7+$41)
        move    x:(r7+$43),a
        tge     y0,a
        move    a,x:(r7+$43)
        move    x:(r7+$45),x1
        and     x1,a
        rts
mo_lofr:
        move    a,y0
        move    x:(r7+$41),a
        tst     a
        move    x:(r7+$44),a
        teq     y0,a
        move    a,x:(r7+$44)
        move    x:(r7+$45),x1
        and     x1,a
        rts

; ---------------------------------------------------------------------------
; momixs -- MIX the wet in $3d/$3e against the dry still in the frame and
; write it back: out = dry + m (wet - dry).
; ---------------------------------------------------------------------------
momixs:
        move    x:(r7+$3d),a
        move    x:(r0),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$00),y1           ; m
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r0)
        move    x:(r7+$3e),a
        move    x:(r0+n0),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$00),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r0+n0)
        rts
