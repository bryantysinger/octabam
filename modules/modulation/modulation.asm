; ---------------------------------------------------------------------------
; MODULATION v2 -- a modulation pedal, six modes, FX1 only (14 Sep 2026).
;
; The modes are transcriptions of published, permissively licensed sources
; (docs/effects/PORTS.md, the modulation survey; the float reference is
; modules/modulation/modulation_ref.py and tools/verify/verify_modulation.py
; proves this code against it):
;
;   JUNO  the Juno-60 chorus (jpcima's HeraChorus.dsp, ISC; pendragon-andyh's
;         measurements): two BBD lines on ONE triangle LFO, the right line's
;         inverted; I 0.513 Hz / II 0.863 Hz over 1.5..5.4 ms; I+II 9.75 Hz
;         mono over 3.2..3.6 ms; the BBD's ~10 kHz in/out filters as one-poles.
;   DIM   the Roland SDD-320 Dimension D: two lines in ANTIPHASE on one
;         triangle LFO (0.25 / 0.5 Hz, 5..12 ms), each side = the dry + a
;         bass lift + a little same-side wet - the OTHER side's wet through a
;         highpass. The amounts are unpublished: OURS (0.25 / -1 / 0.5).
;   ENS   the Solina string ensemble (jpcima string-machine, BSL-1.0): three
;         taps on ONE mono line, delay = 5 ms + 1 ms * (0.5 sin(slow + i/3)
;         + 0.5 sin(fast + i/3)), fast = 10 x slow; L = t1 + t2 - t3,
;         R = t1 - t2 - t3.
;   FLNG  Dattorro's flanger (Effect Design Part 2, JAES 1997, Table 6):
;         blend 0.7071 of the dry read from a FIXED tap at the sweep's centre,
;         feedforward -0.7071 of the swept tap, so the sweep crosses the dry
;         (through-zero) and nulls at the crossing; feedback -0.7071.
;   PHSR  ChowPhaser (BSD-3), the Schulte Compact Phasing A: two RC allpasses
;         (15 nF) with feedback around them, then up to eight first-order
;         allpasses (25 nF) on ONE coefficient; the LDR's law (light = 20.1 -
;         20 lfo, R = 100k (light/0.1)^-0.75, bilinear K = 2 fs) is two
;         33-word tables on the LFO value, read per BLOCK and ramped per
;         sample. The feedback closes through one sample (ChowPhaser solves
;         the delay-free loop as a warped biquad); no tanh stages.
;   COMB  Rings' string loop (Mutable Instruments, MIT): a Hermite-read loop
;         tuned by DLY (8..1,000 samples, exponential), a 3-tap FIR damping
;         filter whose brightness is TONE, and the per-pass gain from a DECAY
;         TIME (rt60 = 0.07 s * 2^(8 lf), lf = d(2-d)) so every pitch rings
;         for the same time. No IIR damping (the MIC_W build's omission), no
;         dispersion. FDBK's sign is ours: negative = odd harmonics.
;
; Every mode outputs the WET only; MIX does the blending, so MIX 0 is an
; exact passthrough in every mode and 127 is the wet outright.
;
; The knobs (page 1: RATE DPTH FDBK MIX TONE WDTH; page 2: DLY MODE):
;   RATE  the LFO, (k/128)^2 * $780 + $10 per sample in 2^23rds of a cycle:
;         0.08 .. 10.0 Hz (the Juno's I+II is 9.75)
;   DPTH  the sweep, 480 * k/128 samples either side of the centre (line
;         modes); the LFO's reach into the LDR's law (PHSR)
;   FDBK  bipolar: (k - 64)/64. Feedback from the swept tap into the line;
;         the phaser's feedback (clamped 0.95); the comb's decay time (its
;         magnitude) and polarity (its sign)
;   MIX   dry .. wet
;   TONE  the BBD proxy: the one-pole in and out of every line, 0.25 (2 kHz)
;         .. 1.0 (open) -- inert in PHSR; the FIR's brightness in COMB
;   WDTH  the right channel's LFO lag, 0 .. half a cycle (127 = antiphase,
;         the Juno's and the Dimension's; 64 = quadrature); inert in ENS
;         (the three phases fix the stereo) and COMB
;   DLY   the centre, 8 + 992 * k/128 samples; the pitch in COMB (a table);
;         the stage count in PHSR (2 / 4 / 6 / 8 by quarters)
;
; ---- FX1 ONLY, ENFORCED HERE ---------------------------------------------
; The base comes from the host's bump allocator, read in INIT and only there
; (docs/firmware/DSP.md section 10: X:0x213 is per-instance during init and
; garbage in proc). FX1 slots are 0x1000 0x1c00 0x2800 0x3400; FX2 slots are
; 0x4000 and up, and every one of those is a server's ground. So a base >=
; 0x4000 sets a flag that sends proc down the DRY path, which writes NOTHING
; to Y. That promise is what Claims(fx1_only=True) declares to the ledger,
; and tools/verify/verify_modulation.py is what proves it.
;
; Two lines of 1,024 words, L at base+0 and R at base+1024 (ENS uses L alone,
; mono): 23 ms each, out of the 3,072 an FX1 slot gives. The read offset is
; MASKED (& $3ff), not the address, so nothing depends on where the allocator
; put us.
;
; ---- r7 slots -------------------------------------------------------------
;   ⚠️ EVERY SLOT THE SAMPLE LOOPS TOUCH IS BELOW $40: an r7 displacement past
;   63 assembles to the two-word long form.
;   per block:
;   $00 m (MIX)          $01 LFO increment     $02 centre Q11.12   $03 depth Q11.12
;   $04 feedback         $05 tone coefficient  $06 WID phase offset
;   $07 bl  $08 bd  $09 ff  $0a kc  $0b kb    (the LINE loop's mix weights)
;   $0c mode (0..5)      $0d dry flag: 1 = FX2 slot or MIX 0
;   $0e line base (per instance)              $0f the P table base
;   $10 scratch (block)  $1a COMB gain  $1b h0  $1c h1  $1d sign  $1e period Q11.12
;   $19 lfo L this sample   $1f lfo R this sample
;   PHSR ramps (PERSISTENT): $11 bm run L  $12 dbm L  $13 bf run L  $14 dbf L
;                            $15 bm run R  $16 dbm R  $17 bf run R  $18 dbf R
;   PERSISTENT: $20 write phase   $21 LFO phase   $22 fast phase (ENS)
;   one-poles: $23 lpi L  $24 lpi R  $25 lpo L  $26 lpo R  $27 hp L  $28 hp R
;              $29 lpb L  $2a lpb R      (ENS: lpi mono $23, lpo 1/2/3 $25..$27)
;   PHSR: $2b/$2c feedback stages L  $2d/$2e R   $2f/$30 y previous L/R
;         mod stages L $23..$2a (the one-poles' slots: never in one block)
;         mod stages R $31..$38
;   COMB: $39/$3a FIR x1/x2 L   $3b/$3c R
;   $3d wet L   $3e wet R   $3f scratch (mo_tap / mo_herm park)
;   $40 the last block's MODE select (per block only: the two-word form is fine)
;
; Every mpy is `mpy x0,y1` (the audited-signed encoding). Every Tcc reads the
; ONE compare above it with nothing but moves between (the flag-clobber
; trap). No label here is a PREFIX of another -- dsp_asm resolves by prefix.
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
        move    (r5)+n5                 ; $11 .. $40
        do      #48,>moiclz
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
; MIX; 127 = 1.0, the wet outright (the through-zero null is exact)
        move    x:(r6+$3),a
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
; WDTH -> the right channel's LFO phase offset, 0 .. half a cycle
        move    x:(r6+$5),a             ; a knob word: bit 23 clear, so a2 = 0
        and     #>$7f0000,a             ; ... and stays 0 through the and
        asr     #$1,a,a
        move    a,x:(r7+$06)
; TONE -> the one-pole coefficient 0.25 + 0.75 * k/128; 127 = 1.0, an exact
; bypass (the flanger's through-zero null needs the blend and the wet alike)
        move    x:(r6+$4),x0
        move    #$60,y1                 ; 0.75 (short immediate: bits 23-16)
        mpy     x0,y1,a
        add     #>$200000,a             ; + 0.25
        move    x:(r6+$4),b
        move    #>$7f0000,x0
        cmp     x0,b                    ; k - 127
        move    #>$7fffff,x0
        tge     x0,a                    ; k >= 127: open
        move    a,x:(r7+$05)
; FDBK -> bipolar, (k - 64)/64: -1 .. +0.984
        move    x:(r6+$2),a
        sub     #>$400000,a             ; k/128 - 0.5
        asl     #$1,a,a
        move    a,x:(r7+$04)
; DLY -> the centre delay in Q11.12 samples, 8 .. 1,000
        move    x:(r6+$c),a
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
; ---- MODE (slot 7 select of r6+$c) ---------------------------------------
; A change of mode clears every state slot $23..$3c (Spectrum's rule: a
; state that meant something else in the last mode is garbage in this one).
        move    x:(r6+$c),a
        and     #>$ff00,a
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
        asr     #$8,a,a
        move    a1,x0
        move    x0,a                    ; the mode, 0..5, clean
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
        beq     mo_bens
        cmp     #>$3,a
        beq     mo_bflng
        cmp     #>$4,a
        beq     mo_bphsr
        cmp     #>$5,a
        beq     mo_bcomb
; JUNO (and any stored value past 5): bl 0, bd 0, ff 1, kc 0, kb 0
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
; unpublished; the highpass and the lift's lowpass are one-poles at 200 Hz)
        clr     a
        move    a,x:(r7+$07)
        move    #>$7fffff,x0
        move    x0,x:(r7+$08)
        move    #>$200000,x0
        move    x0,x:(r7+$09)
        move    #>$800000,x0            ; -1.0
        move    x0,x:(r7+$0a)
        move    #>$400000,x0
        move    x0,x:(r7+$0b)
        bra     mo_line
mo_bflng:
; FLNG: bl 0.7071, bd 0, ff -0.7071, kc 0, kb 0 (Dattorro Table 6)
        clr     a
        move    #>$5a8279,x0            ; 0.7071
        move    x0,x:(r7+$07)
        move    a,x:(r7+$08)
        move    #>$a57d87,x0            ; -0.7071
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
; ENS -- the Solina: three taps on the mono line, two three-phase LFOs
; ===========================================================================
mo_bens:
        move    #$1,n0
        do      n7,>moensz
; ---- the two phases advance: slow by inc, fast by 10 inc ---------------------
        move    x:(r7+$21),a
        move    x:(r7+$01),x0
        add     x0,a
        and     #>$7fffff,a
        move    a1,x:(r7+$21)
        move    x:(r7+$22),a
        move    x:(r7+$01),x0
        add     x0,a
        add     x0,a
        add     x0,a
        add     x0,a
        add     x0,a
        add     x0,a
        add     x0,a
        add     x0,a
        add     x0,a
        add     x0,a
        and     #>$7fffff,a
        move    a1,x:(r7+$22)
; ---- advance the write phase ----------------------------------------------
        move    x:(r7+$20),a
        add     #>$1,a
        and     #>$3ff,a
        move    a1,x:(r7+$20)
; ---- tap 1 (phase offset 0), the one-pole at $25, parked in $3d ---------------
        move    x:(r7+$21),a
        bsr     mo_para
        move    a,x:(r7+$1c)            ; the slow sine
        move    x:(r7+$22),a
        bsr     mo_para
        asr     #$1,a,a
        move    x:(r7+$1c),b
        asr     #$1,b,b
        add     b,a                     ; mod = (slow + fast)/2
        move    a,x0
        move    x:(r7+$03),y1
        mpy     x0,y1,a
        move    x:(r7+$02),x0
        add     x0,a
        clr     b
        move    b,y0
        bsr     mo_tap
        move    x:(r7+$25),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$05),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$25)
        move    a,x:(r7+$3d)            ; t1
; ---- tap 2 (+ 1/3), the one-pole at $26, parked in $3e -------------------------
        move    #>$2aaaaa,x0
        move    x:(r7+$21),a
        add     x0,a
        and     #>$7fffff,a
        bsr     mo_para
        move    a,x:(r7+$1c)
        move    #>$2aaaaa,x0
        move    x:(r7+$22),a
        add     x0,a
        and     #>$7fffff,a
        bsr     mo_para
        asr     #$1,a,a
        move    x:(r7+$1c),b
        asr     #$1,b,b
        add     b,a
        move    a,x0
        move    x:(r7+$03),y1
        mpy     x0,y1,a
        move    x:(r7+$02),x0
        add     x0,a
        clr     b
        move    b,y0
        bsr     mo_tap
        move    x:(r7+$26),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$05),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$26)
        move    a,x:(r7+$3e)            ; t2
; ---- tap 3 (+ 2/3), the one-pole at $27, parked in $1b -------------------------
        move    #>$555555,x0
        move    x:(r7+$21),a
        add     x0,a
        and     #>$7fffff,a
        bsr     mo_para
        move    a,x:(r7+$1c)
        move    #>$555555,x0
        move    x:(r7+$22),a
        add     x0,a
        and     #>$7fffff,a
        bsr     mo_para
        asr     #$1,a,a
        move    x:(r7+$1c),b
        asr     #$1,b,b
        add     b,a
        move    a,x0
        move    x:(r7+$03),y1
        mpy     x0,y1,a
        move    x:(r7+$02),x0
        add     x0,a
        clr     b
        move    b,y0
        bsr     mo_tap
        move    x:(r7+$27),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$05),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$27)
        move    a,x:(r7+$1b)            ; t3
; ---- the line write: LPi((L + R)/2) --------------------------------------------
        move    x:(r0),a
        move    x:(r0+n0),x0
        add     x0,a
        asr     #$1,a,a
        move    x:(r7+$23),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$05),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$23)
        move    a,x:(r7+$10)
        move    x:(r7+$20),a
        move    x:(r7+$0e),x0
        add     x0,a
        move    a,r5
        move    x:(r7+$10),a
        move    a,y:(r5)
; ---- L = t1 + t2 - t3 ; R = t1 - t2 - t3 (limiting stores) -------------------
        move    x:(r7+$3d),a
        move    x:(r7+$3e),x0
        add     x0,a
        move    x:(r7+$1b),x0
        sub     x0,a
        move    x:(r7+$3d),b
        move    x:(r7+$3e),x0
        sub     x0,b
        move    x:(r7+$1b),x0
        sub     x0,b
        move    a,x:(r7+$3d)
        move    b,x:(r7+$3e)
        bsr     momixs
        move    (r0)+n0
        move    (r0)+n0
moensz:
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
; is 1.0; the loop sums all four (branch-free). $1b w2  $1c w4  $1d w6  $1e w8
        clr     a
        move    a,x:(r7+$1b)
        move    a,x:(r7+$1c)
        move    a,x:(r7+$1d)
        move    a,x:(r7+$1e)
        move    x:(r6+$c),a
        and    #>$7f0000,a
        asr     #$15,a,a                ; DLY >> 5: 0..3
        move    a1,n5
        move    r7,r5
        move    (r5)+n5
        move    #$1b,n5
        move    (r5)+n5
        move    #>$7fffff,x0
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
; period from the table on DLY (Q11.12 samples, 1,000 .. 8)
        move    x:(r6+$c),a
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
; the FIR: h0 = (1 + b)/2, h1 = (1 - b)/4, b = TONE/128
        move    x:(r6+$4),a
        asr     #$1,a,a
        add     #>$400000,a
        move    a,x:(r7+$1b)
        move    x:(r6+$4),a
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
        move    a,x:(r7+$3e)            ; wet R
        move    x:(r7+$20),a
        move    x:(r7+$0e),x0
        add     x0,a
        add     #>$400,a
        move    a,r5
        move    x:(r7+$3e),a
        move    a,y:(r5)
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
