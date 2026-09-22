; ---------------------------------------------------------------------------
; SPECTRUM -- a filter pedal: LADR (the zero-delay Moog ladder), LP / BP (the
; zero-delay SEM SVF), ISO (an isolator, Airwindows Capacitor2), VOWL (three
; constant-peak-gain formant resonators morphed by FREQ); ENV and LFO onto
; the cutoff; mid/side WDTH. Insert
; contract (modules/ripple/ripple_svf.asm): frames in place at
; x:(r0)/x:(r0+n0), knobs from r6, state in this instance's r7 block. FX1
; only: init reads the allocator base and an FX2 instance runs as a dry pass.
; Defaults are a bit-exact passthrough. Every mpy is `mpy x0,y1`; every
; clip is the store limiter; every Tcc reads the one compare above it with
; nothing but moves between.
; ---------------------------------------------------------------------------

init:
; ROTINIT
; ---- FX1 ONLY: the allocator base decides, at init --------
; Modulation's idiom (modules/modulation/modulation.asm): X:0x213 points at
; this instance's entry in the base table, valid HERE and nowhere else. FX1
; slots are below 0x4000, FX2 slots at or above it. An FX2 instance runs as
; a dry pass -- proc returns before it touches a frame or the bus -- so a
; part that names this id on FX2 (the stock id both menus share) costs its
; core nothing: the rig's cycle envelope is priced with the stations on FX1
; only (tools/harness/pressure.py), and the FX2 chooser hides them.
; sub/tst rather than cmp: the cmp-encodes-as-max family (CLAUDE.md).
        move    x:>$213,r4
        move    #>$ffffff,m4
        move    x:(r4),x0
        move    x0,a
        move    #>$4000,x0
        sub     x0,a                    ; base - 0x4000
        clr     b                       ; b = 0 BEFORE the tst (the flag trap)
        move    #>$1,x0
        tst     a
        tpl     x0,b                    ; base >= 0x4000: an FX2 slot
; ---- EVERY PERSISTENT SLOT IS ZEROED HERE -------------------
        clr     a
        move    r7,r5
        move    #>$ffffff,m5
        do      #>64,>fs_iz            ; $00..$3f
        move    a,x:(r5)+
fs_iz:
        nop
        move    b,x:(r7+$30)            ; the FX2 flag (1 = dry pass), after the clear
        move    a,x:(r7+$2e)            ; g2run and dg: the ramp starts from 0
        move    a,x:(r7+$2f)
        move    #>$3,x0                 ; CAP's rotation: the third pole of each
        move    x0,x:(r7+$40)           ; sample by count (3 4 5 3 4 5), read
        move    x0,x:(r7+$43)           ; per sample at $40 + count
        move    #>$4,x0
        move    x0,x:(r7+$41)
        move    x0,x:(r7+$44)
        move    #>$5,x0
        move    x0,x:(r7+$42)
        move    x0,x:(r7+$45)
        rts

proc:
        move    x:(r7+$30),a           ; an FX2 slot: dry, nothing written
        tst     a
        bne     fs_end
; (the bus section -- split-aware frame offset, the rotation latch, the registration
; and the r1/r2 accumulator pointers -- left with the sends: the
; stations have carried no send since the one-aux rig of 7 Sep, and the ~70
; words and ~10 cycles a block it cost bought nothing. The station is no
; longer a bus client: Harness(bus_client=False).)
; ===========================================================================
; PER-BLOCK KNOB DECODE
        move    x:(r6+$1),x0
        move    #>$4b2350,y1            ; 0.587
        mpy     x0,y1,a
        neg     a
        add     #>$7fbe77,a             ; base = 0.998 - RES * 0.587  (>= 0.416)
        move    a,x0
        move    a,y1
        mpy     x0,y1,a                 ; base^2
        move    a,x0
        move    a,y1
        mpy     x0,y1,a                 ; base^4 = damp, the Chamberlin form's 1/Q
        asr     #$1,a,a                 ; R = damp/2: the SEM core's damping is 2R
        move    a,x:(r7+$21)            ; (13 Sep 2026: the same dial, the ZDF form)
        move    x:(r6+$4),a             ; a knob word: bit 23 clear, a2 = 0
        and     #>$7f0000,a
        move    a1,x0                   ; (no clean reload: the input was positive)
        move    a1,y1
        move    a1,x1                   ; LSP, kept for the fall below
        mpy     x0,y1,a
        move    a,x0
        move    #>$7000,y1
        mpy     x0,y1,a
        add     #>$100,a
        move    a,x:(r7+$47)            ; lfo inc
        move    x1,x0                   ; LSP again (decoded once, above)
        move    #$0f,y1
        mpy     x0,y1,a                 ; LSP * $1e00 in Q23
        neg     a
        add     #>$7fe000,a
        move    a,x:(r7+$46)            ; fall

; ---- LFO: phase += inc, triangle -> bipolar Q23 ---------------------------
        move    x:(r7+$31),a
        move    x:(r7+$47),x0
        add     x0,a                    ; phase <= $7fffff + inc <= $7100 < 2^24:
        and     #>$7fffff,a             ; no carry into a2, which stays 0
        move    a,x:(r7+$31)
        move    #$40,x0
        sub     x0,a
        abs     a                       ; 0 .. $400000
        move    #$20,x0
        sub     x0,a
        asl     #$1,a,a                 ; -0.5 .. +0.5 -> -1 .. +1
        move    a,x:(r7+$49)            ; lfo, bipolar

; ---- ENV: env = max(last block's peak, env * fall) ------------------------
        move    x:(r7+$1e),x1           ; last block's peak
        move    x:(r7+$32),x0
        move    x:(r7+$46),y1
        mpy     x0,y1,a                 ; env * fall
        cmp     x1,a                    ; nothing between this and the Tcc
        tlt     x1,a                    ; env = max(peak, release)
        move    a,x:(r7+$32)
        clr     a
        move    a,x:(r7+$1e)            ; this block's peak starts at 0

; ---- ENV (slot 2, bipolar) and LDP (slot 3, 0..127): two depths onto the cutoff
        move    x:(r6+$2),a             ; ENV, a knob word (bit 23 clear, a2 = 0)
        and     #>$7f0000,a
        move    #$40,x0
        sub     x0,a
        asl     #$1,a,a                 ; (ENV-64)/64, -1 .. +1
        move    a,x0
        move    x:(r7+$32),y1           ; env (>= 0)
        mpy     x0,y1,a
        move    a,x1                    ; the envelope's term
        move    x:(r6+$3),a             ; LDP
        and     #>$7f0000,a
        move    a,x0                    ; LDP/128
        move    x:(r7+$49),y1           ; lfo, bipolar
        mpy     x0,y1,a                 ; (x0 signed, y1 signed: the audited order)
        add     x1,a
        move    x:(r6+$0),x0            ; FREQ
        add     x0,a                    ; FREQm
        move    #$0,x0
        tmi     x0,a                    ; clamp below at 0
        move    #$7f,x0
        cmp     x0,a
        tgt     x0,a                    ; clamp above at 127/128
        move    a,x1                    ; FREQm, kept
        move    #>$fab1e0,r5            ; the P table -- rewritten by build_bus.py
        move    #>$ffffff,m5
        move    r5,x:(r7+$4e)           ; its base, for VOWL's cosine lookup (the
                                        ; build allows the literal once per module)
        asr     #$12,a,a                ; idx
        move    a1,n5
        move    x1,a
        and     #>$3ffff,a              ; FREQm & (2^18 - 1)   (a2 = 0: FREQm >= 0)
        asl     #$5,a,a                 ; frac, Q23
        move    (r5)+n5
        move    a,x0                    ; frac
        move    p:(r5)+,y0              ; T[idx]
        move    p:(r5),b                ; T[idx+1]
        move    y0,a
        sub     a,b                     ; T[idx+1] - T[idx]  (>= 0: the table rises)
        move    b,y1
        mpy     x0,y1,a                 ; frac * diff
        add     y0,a
        move    a,x:(r7+$20)            ; g2 = tan(pi fc/fs)/2, this block's target
        move    x1,x:(r7+$4f)           ; FREQm, kept for VOWL's morph
; ---- the cutoff RAMP: dg = (g2 - g2run)/16 per block, added
; once per sample in the loop, so a fast FREQ sweep or LFO has no block-rate
; step (the ~2.8 kHz comb of a per-block jump). A 15-sample block reaches
; 15/16 of the way and the next block starts from where it got to.
        move    x:(r7+$2e),x0           ; g2run, where the last block ended
        sub     x0,a
        asr     #$4,a,a
        move    a,x:(r7+$2f)            ; dg
; ---- the SEM core's per-block words: c4 = (R + g2)/2 (so 4*c4 = 2R + g),
; d = 1/(1 + 2Rg + g^2) = (1/8) / (1/8 + R*g2/2 + g2^2/2) -- the one real
; division per block; den/8 <= 0.86 at every knob, d <= 1. Both frozen for
; the block: FM and the ramp move g under a fixed d, an approximation that
; is exact at the block's target and a fraction of a percent off beside it.
        move    x:(r7+$20),a
        move    x:(r7+$21),x0           ; R
        add     x0,a
        asr     #$1,a,a
        move    a,x:(r7+$1f)            ; c4
        move    x:(r7+$20),x0           ; g2
        move    x:(r7+$20),y1
        mpy     x0,y1,a                 ; g2^2
        move    x:(r7+$21),y1           ; R
        mac     x0,y1,a                 ; + R*g2
        add     #>$200000,a             ; + 1/4
        asr     #$1,a,a                 ; den/8
        move    a,x0
        move    #$10,y1                 ; 1/8
        move    y1,a                    ; a clean load: a0 = 0 for the divide
        andi    #$fe,ccr                ; carry clear
        rep     #$18
        div     x0,a                    ; 24 quotient bits land in a0
        move    a0,x0
        move    x0,x:(r7+$33)           ; d

; ---- MODE (slot 6 select of r6+$c, the knob field): tap coefficients; VOWL runs the bank ---
        move    x:(r6+$c),a
        and     #>$ff0000,a
        move    x:(r7+$38),x0
        move    a1,x:(r7+$38)
        sub     x0,a                    ; (a2 = 0: both positive)
        beq     fs_msame
        clr     a
        move    r7,r5
        move    #>$ffffff,m5
        do      #>24,>fs_mclr
        move    a,x:(r5)+
fs_mclr:
        nop
        move    a,x:(r7+$26)
        move    a,x:(r7+$27)
fs_msame:
        clr     a
        move    a,x:(r7+$2d)            ; the SVF alternative unless VOWL says so
        move    a,x:(r7+$23)
        move    a,x:(r7+$24)
        move    a,x:(r7+$25)
        move    #>$7fffff,x0
        move    x:(r6+$c),a             ; MODE, slot 6 = $c's knob field
        and     #>$ff0000,a             ; 0 LADR, 1 SEM, 2 BP, 3 ISO, 4 VOWL
        beq     fs_mladr                ; (LADR first, 14 Sep 2026: "moog is best")
        cmp     #>$20000,a
        beq     fs_mbp
        cmp     #>$30000,a
        beq     fs_mcap
        cmp     #>$40000,a
        beq     fs_mvowl
; SEM (and anything unexpected): SHPE, slot 7 in $c's companion field, is
; the SEM's mode pot -- 0 LP, 64 notch (LP + HP), 127 HP (23 Sep 2026):
; kHP = min(1, k/64), kLP = min(1, (127 - k)/63): both exactly 1 at 64; the
; stores limit.
        move    x:(r6+$c),a
        and     #>$7f00,a               ; k<<8
        move    a1,x0
        move    x0,a                    ; A2-clean (AND cleans A1 only)
        asl     #$9,a,a                 ; k<<17 = k/64 as Q23
        move    a,x:(r7+$25)            ; kHP
        move    #>$7f00,b
        sub     x0,b                    ; (127 - k)<<8
        asl     #$8,b,b                 ; (127 - k)/128 as Q23
        move    b,x0
        move    #>$410410,y1            ; (128/63)/4
        mpy     x0,y1,b
        asl     #$2,b,b                 ; (127 - k)/63
        move    b,x:(r7+$23)            ; kLP
        bra     fs_mdone
fs_mbp:
        move    x0,x:(r7+$24)
        bra     fs_mdone
fs_mcap:
; ---- ISO: Airwindows Capacitor2 (Chris Johnson, MIT), the
; isolator with a dielectric: a lowpass and a highpass (LOW = FREQ, HIGH =
; RES here, the knobs renamed by the mode) whose one-pole amounts are the
; knob squared, chased 1/16 per block, and per sample scaled by the signal
; itself -- |1 - x/nl|, nl = 1 + 6 (1 - NLIN/128) -- six poles per channel
; rotated three-at-a-time (modules/spectrum/capacitor2_ref.py). Per block:
; $26 lpBase, $27 hpBase (persistent chases), $28 1/nl, $29 trim/2 =
; 0.75/cbrt(nl) fitted in NLIN.
        move    #>$3,x0
        move    x0,x:(r7+$2d)           ; the loop runs the capacitor
        move    x:(r7+$4f),x0           ; FREQm
        move    x:(r7+$4f),y1
        mpy     x0,y1,a                 ; (FREQm)^2
        move    a,x0
        move    #>$7f7cee,y1            ; 0.996
        mpy     x0,y1,a
        add     #>$008312,a             ; + 0.004
        move    x:(r7+$26),x0
        sub     x0,a
        asr     #$4,a,a
        add     x0,a
        move    a,x:(r7+$26)            ; lpBase += (target - lpBase)/16
; the high-pass side is a fixed 2^-12 (a ~2 Hz corner: a DC block, never a
; frozen pole) -- option B: one cutoff, one flavour, so ISO's
; separate HIGH cut went and RES became the dielectric's colour (COLR).
        move    #>$000800,x0
        move    x0,x:(r7+$27)           ; hpBase
        move    x:(r6+$1),x0            ; C = RES/128, drawn COLR in ISO
        move    #$60,y1                 ; 6/8
        mpy     x0,y1,a
        neg     a
        add     #>$700000,a             ; nl/8 = 7/8 - 6C/8, 1/8 .. 7/8
        move    a,x1                    ; the denominator
        move    #>$0f0000,y1            ; 15/128
        mpy     x0,y1,a
        add     #>$010000,a             ; (1 + 15C)/128, < nl/8 always
        move    x1,x0
        andi    #$fe,ccr
        rep     #$18
        div     x0,a
        move    a0,x0
        move    x0,x:(r7+$28)           ; gn/16 = (1 + 15C)/(16 nl), <= 0.993
        move    x:(r6+$1),x0
        move    x:(r6+$1),y1
        mpy     x0,y1,a                 ; C^2
        move    a,x0
        move    #>$326e98,y1            ; 0.394
        mpy     x0,y1,a
        move    x:(r6+$1),x0
        move    #>$fb6db7,y1            ; -0.036
        mac     x0,y1,a
        add     #>$322d0e,a             ; + 0.392: trim/2 = 0.75/cbrt(nl), fitted
        move    a,x:(r7+$29)
        bra     fs_mdone
fs_mvowl:
        move    x:(r6+$1),a             ; RES/128
        asr     #$1,a,a
        add     #>$400000,a
        move    a,x:(r7+$48)            ; vg/8
; ---- VOWL: three parallel constant-peak-gain resonators
; (audiojs formant / resonator, JOS's two-zero form, MIT) replace the
; two-peak trick. Per formant y = b0*(x - x2) + 2*m1*y1 - a2*y2 with
; R = exp(-pi*bw/fs), m1 = R*cos(w0), a2 = R^2, b0 = (1-R^2)/2; gains
; 1 / 0.5 / 0.3. FREQm (post-modulation, so DPTH and the LFO sweep the
; vowels) morphs A E I O U: idx = FREQm >> 21 (0..3) picks the pair, frac =
; the 5 bits under it. RES narrows the bandwidths: R' = R + 0.9(1-R)*RES.
; ROUT is left as decoded -- the bank is filter A, B and the mix
; run as in every other mode; FM has no cutoff to move here.
        move    #>$1,x0
        move    x0,x:(r7+$2d)           ; the loop runs the bank, not the SVF
        move    x:(r7+$4f),a            ; FREQm
        asr     #$10,a,a
        and     #>$1f,a
        asl     #$12,a,a                ; (FREQm >= 0, so a2 = 0 throughout)
        move    a1,x:(r7+$49)           ; frac (the lfo park is dead by now)
        move    x:(r7+$4f),a
        asr     #$15,a,a                ; idx 0..3 (FREQm >= 0: a2 clean)
        move    a1,x0
        move    x0,a
        move    a,b
        add     x0,b
        add     x0,b                    ; 3*idx
        move    b1,n5
        move    x:(r7+$4e),r5           ; the P table's base (saved at the g2 lookup)
        move    #>$ffffff,m5
        move    (r5)+n5
        move    #$21,n5                 ; 33
        move    (r5)+n5                 ; r5 = COS_TABLE[idx][0] (33 words past G2)
        move    #$3,n5
; ONE loop over the three formants (14 Sep 2026; it was three copies of the
; block, 27 words each). The coefficient slots are stride-1 per formant --
; m1 at $10..$12, a2 at $13..$15, b0 at $16..$18 -- so r3 = r7 + $10 + k and
; the stores are r3-relative; the only per-formant constants, e_k and R_k,
; sit in the P table after the COS table (manifest VOWL_ER) and r2 walks
; them. m3 is linear here as it is in the sample loop, which addresses
; through r3 the same way.
        move    x:(r7+$4e),r2           ; the P table's base ...
        move    #>$ffffff,m2
        move    #$30,n2
        move    (r2)+n2                 ; ... + 48: the (e_k, R_k) pairs
        move    r7,r3
        move    #$10,n3
        move    (r3)+n3                 ; r3 = r7 + $10, formant 0's m1
        do      #3,>fs_vfz
; formant k: cw = CW[idx][k] + frac*(CW[idx+1][k] - CW[idx][k]) (p:(r5)+n5
; reads the first and steps to the next vowel, p:(r5)-n5 reads it and steps
; back; (r5)+ moves to the next formant); R' = R_k + e_k*RES narrows the band
; with RES; m1 = R'*cw = -a1/2, a2 = R'^2, b0 = (1 - a2)/2.
        move    p:(r5)+n5,y0            ; CW[idx][k]
        move    p:(r5)-n5,b             ; CW[idx+1][k]
        move    (r5)+
        move    y0,a
        sub     a,b                     ; diff
        move    b,x0
        move    x:(r7+$49),y1           ; frac
        mpy     x0,y1,a
        add     y0,a                    ; cw
        move    a,x1
        move    x:(r6+$1),x0            ; RES/128
        move    p:(r2)+,y1              ; e_k = 0.9*(1 - R_k)
        mpy     x0,y1,a
        move    p:(r2)+,y0              ; R_k = exp(-pi*bw_k/fs)
        add     y0,a                    ; R' (the immediate add it replaces
                                        ; summed the same 24-bit word into a1)
        move    a,y1                    ; R' (> 0: the SEND-safe second operand)
        mpy     x1,y1,b                 ; m1 = cw*R'
        move    b,x:(r3)                ; $10 + k
        move    a,x0
        mpy     x0,y1,b                 ; a2 = R'^2
        move    b,x:(r3+$3)             ; $13 + k
        asr     #$1,b,b
        neg     b
        add     #>$400000,b             ; b0 = 1/2 - a2/2
        move    b,x:(r3+$6)             ; $16 + k
        move    (r3)+
fs_vfz:
        nop
        bra     fs_mdone
fs_mladr:
; ---- LADR: the Moog transistor ladder, the LINEAR zero-delay
; 4-pole (audiojs/filter moogLadder without its tanh; Zavalishin ch. 6): per
; block G = g/(1+g) = (g2/2)/(1/4 + g2/2) by the second real division, its
; powers, k/4 = 0.975*RES/128 (the linear ladder oscillates at k = 4; 3.9
; rings hard and the limiting stores bound it), d/2 = (1/4)/(1/2 + 2*(k/4)*G^4)
; by a third. Per sample (the loop's third alternative): S/8 from the four
; states stored HALVED (s/2 in $00..$03 L, $08..$0b R -- VOWL's slots, the
; two modes never run in one block), u = (x - k*S)*d, four trapezoidal
; stages y = G'(v - s) + s, s' = 2y - s, out = y4. G ramps per sample as g2
; does ($16 Grun += $15 dG), FM moves G' multiplicatively with the block's
; powers frozen (the same approximation as the SEM's frozen d). Slots:
; $10 G  $11 G(1-G)  $12 G^2(1-G)  $17 G^3(1-G)  $18 1-G  $13 k/4  $14 d/2
; $15 dG  $16 Grun ($17/$18 are VOWL's b0 slots: one mode per block).
        move    #>$2,x0
        move    x0,x:(r7+$2d)           ; the loop runs the ladder
        move    x:(r6+$1),x0            ; RES/128
        move    #>$7ccccd,y1            ; 0.975
        mpy     x0,y1,a
        move    a,x:(r7+$13)            ; k/4
        move    x:(r7+$20),a            ; g2, this block's target
        asr     #$1,a,a                 ; g2/2, the numerator
        move    a,x1
        add     #>$200000,a             ; den = 1/4 + g2/2  (<= 0.71)
        move    a,x0
        move    x1,a                    ; a clean load: a0 = 0, num < den
        andi    #$fe,ccr
        rep     #$18
        div     x0,a
        move    a0,x0                   ; G = g/(1+g), <= 0.65
        move    x0,x:(r7+$10)           ; G, the ramp's target
        move    x0,y1
        mpy     x0,y1,a                 ; G^2
        move    a,x0
        move    a,y1
        mpy     x0,y1,a                 ; G^4
        move    a,x0
        move    x:(r7+$13),y1           ; k/4
        mpy     x0,y1,a                 ; (k/4) G^4
        asl     #$1,a,a                 ; 2 (k/4) G^4 = k G^4 / 2  (<= 0.34)
        add     #>$400000,a             ; den = 1/2 + k G^4 / 2
        move    a,x0
        move    #$20,a                  ; num = 1/4 (a2 = a0 = 0): d/2 = (1/4)/den, <= 1/2
        andi    #$fe,ccr
        rep     #$18
        div     x0,a
        move    a0,x0
        move    x0,x:(r7+$14)           ; d/2
        move    x:(r7+$10),y1           ; G
        move    #>$7fffff,a
        sub     y1,a
        move    a,x:(r7+$18)            ; 1-G
        move    a,x0
        mpy     x0,y1,a
        move    a,x:(r7+$11)            ; G(1-G)
        move    a,x0
        mpy     x0,y1,a
        move    a,x:(r7+$12)            ; G^2(1-G)
        move    a,x0
        mpy     x0,y1,a
        move    a,x:(r7+$17)            ; G^3(1-G)
        move    x:(r7+$10),a            ; G
        move    x:(r7+$16),x0           ; Grun, where the last block ended
        sub     x0,a
        asr     #$4,a,a
        move    a,x:(r7+$15)            ; dG
fs_mdone:
; ---- WDTH (slot 5; slot 4 until LSP took it): stereo width of
; the output, Character's mid/side, drawn -64..+63; the knob word IS WDTH/128
; = the side gain HALVED (64 -> 0.5, doubled back per sample: 0 = mono, 127 =
; double sides).
        move    x:(r6+$5),a
        and     #>$7f0000,a
        move    a,x:(r7+$2c)            ; ($25 is the SVF's HP tap -- 14 Sep 2026's first build put this there and every LP leaked half its HP)

; ---- BYPASS: the defaults are a bit-exact passthrough ---------------------
; FREQ 127, RES 0, ENV 64, LDP 0, WDTH 64, MODE 0 (LSP is inert at LDP 0 / ENV 64; slot 6 is blank).
; Every part that ever chose stock FILTER runs this on FX1 after the flash,
; so the neutral block copies nothing at all.
        clr     b
        move    x:(r6+$0),a
        move    #$7f,x0
        cmp     x0,a
        bne     fs_live
        move    x:(r6+$1),a
        tst     a
        bne     fs_live
        move    #$40,x0
        move    x:(r6+$2),a
        cmp     x0,a
        bne     fs_live
        move    x:(r6+$3),a
        tst     a
        bne     fs_live
        move    x:(r6+$5),a
        cmp     x0,a
        bne     fs_live
        move    x:(r6+$c),a             ; the MODE select (slot 6, the knob field
        and     #>$ff0000,a             ; since 16 Sep 2026)
        bne     fs_live                 ; AND sets Z from A1 (a2 = a0 = 0 here)
        bra     fs_bypass
fs_live:

; ===========================================================================
; THE SAMPLE LOOP -- one MODEFORK: the SEM SVF, or the VOWL bank; filter B
; and the mix are one straight-line callee both alternatives call per
; channel (13 Sep 2026). CYCLES_FORWARD_BRANCHES: the fork's dispatch is the
; only branch, and the pricer charges dispatch + the worst alternative.
; ===========================================================================
        move    #$1,n0                  ; (short immediate, stock's own form)
; ---- the SVF's pointer bases (22 Sep 2026): r4 -> the coefficient stream
; at $50 (c4 d kLP kHP kBP for L, then for R), r6 -> the states at $34;
; r1/r2 walk copies of them every sample. r6 is the page pointer, which
; nothing reads after this point (the dispatcher reloads it).
        move    r7,r4
        move    #$50,n4
        move    (r4)+n4
        move    #>$ffffff,m4
        move    r4,r1
        move    #>$ffffff,m1
        move    x:(r7+$1f),x0           ; c4
        move    x0,x:(r1)+
        move    x:(r7+$33),x0           ; d
        move    x0,x:(r1)+
        move    x:(r7+$23),x0           ; kLP
        move    x0,x:(r1)+
        move    x:(r7+$25),x0           ; kHP
        move    x0,x:(r1)+
        move    x:(r7+$24),x0           ; kBP
        move    x0,x:(r1)+
        move    x:(r7+$1f),x0           ; the same five for R
        move    x0,x:(r1)+
        move    x:(r7+$33),x0
        move    x0,x:(r1)+
        move    x:(r7+$23),x0
        move    x0,x:(r1)+
        move    x:(r7+$25),x0
        move    x0,x:(r1)+
        move    x:(r7+$24),x0
        move    x0,x:(r1)+
        move    r7,r6
        move    #$34,n6
        move    (r6)+n6
        move    #>$ffffff,m2
; LADR's stream at $60 on r2: G^3(1-G) G^2(1-G) G(1-G) 1-G k/4 d/2 (G' per
; sample) for L, the same for R
        move    r7,r2
        move    #$60,n2
        move    (r2)+n2
        move    r2,r1
        move    x:(r7+$17),x0
        move    x0,x:(r1)+
        move    x:(r7+$12),x0
        move    x0,x:(r1)+
        move    x:(r7+$11),x0
        move    x0,x:(r1)+
        move    x:(r7+$18),x0
        move    x0,x:(r1)+
        move    x:(r7+$13),x0
        move    x0,x:(r1)+
        move    x:(r7+$14),x0
        move    x0,x:(r1)+
        move    (r1)+                   ; slot 6: G', per sample
        move    x:(r7+$17),x0
        move    x0,x:(r1)+
        move    x:(r7+$12),x0
        move    x0,x:(r1)+
        move    x:(r7+$11),x0
        move    x0,x:(r1)+
        move    x:(r7+$18),x0
        move    x0,x:(r1)+
        move    x:(r7+$13),x0
        move    x0,x:(r1)+
        move    x:(r7+$14),x0
        move    x0,x:(r1)+
; VOWL's stream at $70 on r5: b0 m1 a2 for each formant, then vg/8
        move    r7,r5
        move    #$70,n5
        move    (r5)+n5
        move    #>$ffffff,m5
        move    r5,r1
        move    x:(r7+$16),x0
        move    x0,x:(r1)+
        move    x:(r7+$10),x0
        move    x0,x:(r1)+
        move    x:(r7+$13),x0
        move    x0,x:(r1)+
        move    x:(r7+$17),x0
        move    x0,x:(r1)+
        move    x:(r7+$11),x0
        move    x0,x:(r1)+
        move    x:(r7+$14),x0
        move    x0,x:(r1)+
        move    x:(r7+$18),x0
        move    x0,x:(r1)+
        move    x:(r7+$12),x0
        move    x0,x:(r1)+
        move    x:(r7+$15),x0
        move    x0,x:(r1)+
        move    x:(r7+$48),x0
        move    x0,x:(r1)+
        do      n7,>fs_end
; ---- input peak for the envelope follower (mono, pre-filter) --------------
        move    x:(r0),a
        move    x:(r0+n0),x0
        add     x0,a
        asr     #$1,a,a
        abs     a
        move    x:(r7+$1e),x0
        cmp     x0,a
        tlt     x0,a
        move    a,x:(r7+$1e)
; ---- the cutoff ramp: g2run += dg, once per sample for both channels -------
        move    x:(r7+$2e),a
        move    x:(r7+$2f),x0
        add     x0,a
        move    a,x:(r7+$2e)            ; limited: g2 never past the rail
; MODEFORK_BEGIN -- cycle_count.py: the dispatch, one flag test (0 = the SVF;
; the second alternative's head tells 1 = VOWL from 2 = LADR)
        move    x:(r7+$2d),a
        tst     a
        bne     fs_v_or_l
; MODEFORK_MID -- alternative 1: the SEM zero-delay SVF, LP / BP
; Pointer-addressed since 22 Sep 2026 (the displaced move costs at least two
; cycles more than a pointer move on the chip, measured): r1 walks this
; block's coefficient stream (c4 d kLP kHP kBP, once per channel, written
; before the loop at $50), r2 walks the states s0L s1L s0R s1R at $34; hp,
; bp and lp stay in registers. The arithmetic is the 14 Sep engine's,
; instruction for instruction: bit-identical (the six-render gate).
        move    r4,r1                   ; the stream
        move    r6,r2                   ; the states
; ===================== channel L =====================
        move    x:(r0),x1               ; x
        move    x:(r2)+,x0              ; s0
        move    x0,y0                   ; s0, kept for bp
        move    x:(r1)+,y1              ; c4 = (R + g2)/2
        mpy     x0,y1,a
        asl     #$2,a,a                 ; (2R + g) * s0
        move    x:(r2)-,x0              ; s1 (r2 back on s0)
        add     x0,a
        move    x1,b
        sub     a,b                     ; t
        asr     #$3,b,b
        move    b,x0                    ; t8, |t8| <= 0.63
        move    x:(r1)+,y1              ; d
        mpy     x0,y1,a
        asl     #$3,a,a
        move    a,x0                    ; hp, limited -- the resonance clamp
        move    a,x1                    ; hp, kept for the tap (x is spent)
        move    x:(r7+$2e),y1           ; g2 = g2run this sample
        mpy     x0,y1,b
        asl     #$1,b,b                 ; p = g*hp
        move    y0,a                    ; s0
        add     b,a                     ; bp
        move    a,y0                    ; bp, limited, kept for the tap
        add     b,a
        move    a,x:(r2)+               ; s0' (r2 -> s1)
        move    y0,x0
        mpy     x0,y1,b                 ; y1 is still g2
        asl     #$1,b,b                 ; q = g*bp
        move    x:(r2),a                ; s1
        add     b,a                     ; lp
        move    a,x0                    ; lp, limited, for the tap
        add     b,a
        move    a,x:(r2)+               ; s1' (r2 -> the next channel's s0)
; wetA = kLP*lp + kHP*hp + kBP*bp (exact in the accumulator, any order)
        move    x:(r1)+,y1              ; kLP
        mpy     x0,y1,a
        move    x1,x0                   ; hp
        move    x:(r1)+,y1              ; kHP
        mac     x0,y1,a
        move    y0,x0                   ; bp
        move    x:(r1)+,y1              ; kBP
        mac     x0,y1,a
        move    a,x:(r0)                ; out (limited)
; ===================== channel R =====================
        move    x:(r0+n0),x1               ; x
        move    x:(r2)+,x0              ; s0
        move    x0,y0                   ; s0, kept for bp
        move    x:(r1)+,y1              ; c4 = (R + g2)/2
        mpy     x0,y1,a
        asl     #$2,a,a                 ; (2R + g) * s0
        move    x:(r2)-,x0              ; s1 (r2 back on s0)
        add     x0,a
        move    x1,b
        sub     a,b                     ; t
        asr     #$3,b,b
        move    b,x0                    ; t8, |t8| <= 0.63
        move    x:(r1)+,y1              ; d
        mpy     x0,y1,a
        asl     #$3,a,a
        move    a,x0                    ; hp, limited -- the resonance clamp
        move    a,x1                    ; hp, kept for the tap (x is spent)
        move    x:(r7+$2e),y1           ; g2 = g2run this sample
        mpy     x0,y1,b
        asl     #$1,b,b                 ; p = g*hp
        move    y0,a                    ; s0
        add     b,a                     ; bp
        move    a,y0                    ; bp, limited, kept for the tap
        add     b,a
        move    a,x:(r2)+               ; s0' (r2 -> s1)
        move    y0,x0
        mpy     x0,y1,b                 ; y1 is still g2
        asl     #$1,b,b                 ; q = g*bp
        move    x:(r2),a                ; s1
        add     b,a                     ; lp
        move    a,x0                    ; lp, limited, for the tap
        add     b,a
        move    a,x:(r2)+               ; s1' (r2 -> the next channel's s0)
; wetA = kLP*lp + kHP*hp + kBP*bp (exact in the accumulator, any order)
        move    x:(r1)+,y1              ; kLP
        mpy     x0,y1,a
        move    x1,x0                   ; hp
        move    x:(r1)+,y1              ; kHP
        mac     x0,y1,a
        move    y0,x0                   ; bp
        move    x:(r1)+,y1              ; kBP
        mac     x0,y1,a
        move    a,x:(r0+n0)                ; out (limited)
        bra     fs_join
; MODEFORK_MID -- alternative 2: VOWL, the three-formant bank
fs_v_or_l:
        move    #>$1,x0
        cmp     x0,a
        beq     fs_vowl
        move    #>$2,x0
        cmp     x0,a
        bne     fs_cap                  ; 3: the capacitor (the fourth alternative)
        bra     fs_ladr
fs_vowl:
; pointer-addressed (22 Sep 2026): r5 -> the block's stream at $70 (b0 m1 a2
; per formant, then vg/8), r3 -> the channel's eight states (x1 x2, then y1 y2
; per formant), n3 = 2 steps the pair.
; ===================== channel L =====================
        move    x:(r0),x1          ; x (DRV retired: x_d == x)
        move    r7,r3                   ; states at $00
        move    #$2,n3
        move    r5,r1                   ; the stream: b0 m1 a2 x3, vg/8
; dx/2 = (x_d - x2)/2, shared by the three resonators; then x2 <- x1 <- x_d
        move    x:(r3),y0               ; x1
        move    x1,x:(r3)+              ; x1 <- x_d
        move    x:(r3),x0               ; x2
        move    y0,x:(r3)+              ; x2 <- x1; r3 -> formant 0's y1
        move    x1,a
        sub     x0,a
        asr     #$1,a,a
        move    a,x1                    ; dx/2 (|.| <= 1)
; formant 0: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x1,x0                   ; dx/2
        move    x:(r1)+,y1              ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r3)+,x0              ; y1
        move    x:(r1)+,y1              ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x0,b                    ; y1, for the shift
        move    x:(r3),x0               ; y2
        move    b,x:(r3)-               ; y2 <- y1
        move    x:(r1)+,y1              ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    a,x:(r3)+n3             ; y1 <- y (limited); on to the next pair
        move    a,x0                    ; y, limited
        move    #$40,y1                 ; the formant's gain, halved
        mpy     x0,y1,a
        move    a,y0                    ; the sum so far (halved)
; formant 1: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x1,x0                   ; dx/2
        move    x:(r1)+,y1              ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r3)+,x0              ; y1
        move    x:(r1)+,y1              ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x0,b                    ; y1, for the shift
        move    x:(r3),x0               ; y2
        move    b,x:(r3)-               ; y2 <- y1
        move    x:(r1)+,y1              ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    a,x:(r3)+n3             ; y1 <- y (limited); on to the next pair
        move    a,x0                    ; y, limited
        move    #$20,y1                 ; the formant's gain, halved
        mpy     x0,y1,a
        add     y0,a
        move    a,y0                    ; the sum so far (halved)
; formant 2: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x1,x0                   ; dx/2
        move    x:(r1)+,y1              ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r3)+,x0              ; y1
        move    x:(r1)+,y1              ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x0,b                    ; y1, for the shift
        move    x:(r3),x0               ; y2
        move    b,x:(r3)-               ; y2 <- y1
        move    x:(r1)+,y1              ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    a,x:(r3)+n3             ; y1 <- y (limited); on to the next pair
        move    a,x0                    ; y, limited
        move    #>$133333,y1          ; the formant's gain, halved
        mpy     x0,y1,a
        add     y0,a
        move    a,y0                    ; the sum so far (halved)
; wetA = 2 * the halved sum (= y0 + 0.5*y1 + 0.3*y2), limited -- as sum + sum,
; NOT an asl: a0 still holds the last product's low bits and a shift would
; carry its top bit into a1; the add leaves a2:a1 exactly as the shift of the
; reloaded sum did
        add     y0,a
        move    a,x0                    ; wetA (limited)
        move    x:(r1)+,y1              ; vg/8
        mpy     x0,y1,a
        asl     #$3,a,a                 ; wetA * vg, the store limits
        move    a,x:(r0)           ; out (limited)
; ===================== channel R =====================
        move    x:(r0+n0),x1       ; x (DRV retired: x_d == x)
        move    r7,r3
        move    #$8,n3
        move    (r3)+n3                 ; states at $08
        move    #$2,n3
        move    r5,r1                   ; the stream: b0 m1 a2 x3, vg/8
; dx/2 = (x_d - x2)/2, shared by the three resonators; then x2 <- x1 <- x_d
        move    x:(r3),y0               ; x1
        move    x1,x:(r3)+              ; x1 <- x_d
        move    x:(r3),x0               ; x2
        move    y0,x:(r3)+              ; x2 <- x1; r3 -> formant 0's y1
        move    x1,a
        sub     x0,a
        asr     #$1,a,a
        move    a,x1                    ; dx/2 (|.| <= 1)
; formant 0: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x1,x0                   ; dx/2
        move    x:(r1)+,y1              ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r3)+,x0              ; y1
        move    x:(r1)+,y1              ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x0,b                    ; y1, for the shift
        move    x:(r3),x0               ; y2
        move    b,x:(r3)-               ; y2 <- y1
        move    x:(r1)+,y1              ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    a,x:(r3)+n3             ; y1 <- y (limited); on to the next pair
        move    a,x0                    ; y, limited
        move    #$40,y1                 ; the formant's gain, halved
        mpy     x0,y1,a
        move    a,y0                    ; the sum so far (halved)
; formant 1: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x1,x0                   ; dx/2
        move    x:(r1)+,y1              ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r3)+,x0              ; y1
        move    x:(r1)+,y1              ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x0,b                    ; y1, for the shift
        move    x:(r3),x0               ; y2
        move    b,x:(r3)-               ; y2 <- y1
        move    x:(r1)+,y1              ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    a,x:(r3)+n3             ; y1 <- y (limited); on to the next pair
        move    a,x0                    ; y, limited
        move    #$20,y1                 ; the formant's gain, halved
        mpy     x0,y1,a
        add     y0,a
        move    a,y0                    ; the sum so far (halved)
; formant 2: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x1,x0                   ; dx/2
        move    x:(r1)+,y1              ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r3)+,x0              ; y1
        move    x:(r1)+,y1              ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x0,b                    ; y1, for the shift
        move    x:(r3),x0               ; y2
        move    b,x:(r3)-               ; y2 <- y1
        move    x:(r1)+,y1              ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    a,x:(r3)+n3             ; y1 <- y (limited); on to the next pair
        move    a,x0                    ; y, limited
        move    #>$133333,y1          ; the formant's gain, halved
        mpy     x0,y1,a
        add     y0,a
        move    a,y0                    ; the sum so far (halved)
; wetA = 2 * the halved sum (= y0 + 0.5*y1 + 0.3*y2), limited -- as sum + sum,
; NOT an asl: a0 still holds the last product's low bits and a shift would
; carry its top bit into a1; the add leaves a2:a1 exactly as the shift of the
; reloaded sum did
        add     y0,a
        move    a,x0                    ; wetA (limited)
        move    x:(r1)+,y1              ; vg/8
        mpy     x0,y1,a
        asl     #$3,a,a                 ; wetA * vg, the store limits
        move    a,x:(r0+n0)        ; out (limited)
        bra     fs_join
; MODEFORK_MID -- alternative 3: LADR, the linear zero-delay Moog ladder
fs_ladr:
; the per-sample ramp: Grun += dG, then G' = min(Grun, $7f0000) into both
; channels' stream slots (22 Sep 2026: the FM term was a multiply by zero
; since 14 Sep, so G' is the clamped ramp exactly). Pointer-addressed: r2 ->
; this block's LADR stream at $60 (G^3(1-G) G^2(1-G) G(1-G) 1-G k/4 d/2 G'
; per channel), r3 -> the states; x in b, wetA back in a.
        move    x:(r7+$16),a
        move    x:(r7+$15),x0
        add     x0,a
        move    a,x:(r7+$16)            ; limited: G never past the rail
        move    #$7f,x0
        cmp     x0,a
        tgt     x0,a                    ; G' < 1
        move    r2,r1
        move    #$6,n1
        move    (r1)+n1
        move    #$7,n1
        move    a,x:(r1)+n1             ; G' for L (slot 6)
        move    a,x:(r1)                ; G' for R (slot 13)
        move    r2,r1
; ===================== channel L =====================
        move    x:(r0),b                ; x
        move    r7,r3                   ; states s0..s3 at $00
        bsr     fs_lcore
        move    a,x:(r0)                ; out (limited)
; ===================== channel R =====================
        move    x:(r0+n0),b
        move    r7,r3
        move    #$8,n3
        move    (r3)+n3                 ; states s0..s3 at $08
        bsr     fs_lcore
        move    a,x:(r0+n0)
        bra     fs_join
; MODEFORK_MID -- alternative 4: CAP, Airwindows Capacitor2 (MIT; 14 Sep 2026)
fs_cap:
; the rotation: count = (count + 1) mod 6 picks which two of the five moving
; pole pairs join pole A this sample (B or C, then D, E or F); the offsets
; come from a six-word table at $40 written at init. o1 -> n4, o2 -> n6.
        move    x:(r7+$22),a
        add     #>$1,a
        move    #>$6,x0
        cmp     x0,a
        move    #>$0,x1
        tge     x1,a
        move    a,x:(r7+$22)
        move    r7,r3
        move    #>$40,n3
        move    (r3)+n3
        move    a1,n3
        and     #>$1,a
        add     #>$1,a                  ; o1 = 1 or 2
        move    a1,n4
        move    x:(r3+n3),a             ; o2 = 3, 4 or 5
        move    a1,n6
; ===================== channel L =====================
        move    x:(r0),a
        move    r7,r3                   ; L states: hp A..F at $00, lp A..F at $06
        bsr     fs_ccore
        move    a,x:(r0)                ; out (limited)
; ===================== channel R =====================
        move    x:(r0+n0),a
        move    r7,r3
        move    #$0c,n3
        move    (r3)+n3                 ; R states at $0c / $12
        bsr     fs_ccore
        move    a,x:(r0+n0)
; MODEFORK_END
fs_join:
; ---- WDTH: mid stays, side scales (Character's width) --------
        move    x:(r0),a                ; L
        move    x:(r0+n0),x0            ; R
        add     x0,a
        asr     #$1,a,a
        move    a,x1                    ; mid
        move    x:(r0),a
        sub     x0,a
        asr     #$1,a,a
        move    a,x0                    ; side
        move    x:(r7+$2c),y1           ; side gain / 2
        mpy     x0,y1,a
        asl     #$1,a,a
        move    a,y0                    ; scaled side
        move    x1,a
        add     y0,a
        move    a,x:(r0)
        move    x1,a
        sub     y0,a
        move    a,x:(r0+n0)
        move    (r0)+n0                 ; the frame advance: n0 is 1 for the
        move    (r0)+n0                 ; whole loop, so two steps, no reload
fs_end:
        nop
        rts

; ---------------------------------------------------------------------------
; fs_ccore -- Capacitor2 for one channel (Airwindows, MIT;).
; In: a = x, r3 -> the channel's twelve states (hp A..F at +0..5, lp A..F at
; +6..11), n4 = o1 (1/2), n6 = o2 (3/4/5) this sample.
; Out: a = x through pole A, the o1 pair and the o2 pair, times trim.
; scale/2 = |1/2 - x/(2 nl)|; amt/2 = base * scale/2; each pole is
; s' = s (1 - amt) + x amt (the second mac doubles the halved amount), a
; highpass takes x - s', a lowpass takes s'. STRAIGHT-LINE. Pointer-addressed
; (22 Sep 2026): the four amounts (1-hpAmt hpAmt/2 1-lpAmt lpAmt/2) sit in a
; four-word ring at $7c read round by r1 (m1 = 3: one turn per pole pair),
; r5 = r3 + 6 is the lowpass states (n3 = n5 = the pair's offset), x1 the
; running x. Clobbers x0, x1, y0, y1, b, r1, m1, r5, n3, n5.
; ---------------------------------------------------------------------------
fs_ccore:
        move    r7,r1
        move    #$7c,n1
        move    (r1)+n1
        move    #$3,m1
        move    r3,r5
        move    #$6,n5
        move    (r5)+n5
        move    a,x1                    ; x (the dry drives the dielectric)
        move    a,x0
        move    x:(r7+$28),y1           ; gn/16
        mpy     x0,y1,a                 ; g x / (16 nl)
        asl     #$3,a,a                 ; g x / (2 nl)
        neg     a
        add     #>$400000,a             ; 1/2 - g x/(2 nl)
        abs     a
        move    a,x0                    ; scale/2, 0 .. 1 (clipped: the plugin's own bound)
        move    x:(r7+$27),y1           ; hpBase
        mpy     x0,y1,a
        move    (r1)+
        move    a,x:(r1)-               ; ring 1: hpAmt/2
        asl     #$1,a,a
        neg     a
        add     #>$7fffff,a
        move    a,x:(r1)+               ; ring 0: 1 - hpAmt
        move    (r1)+
        move    x:(r7+$26),y1           ; lpBase
        mpy     x0,y1,a
        move    (r1)+
        move    a,x:(r1)-               ; ring 3: lpAmt/2
        asl     #$1,a,a
        neg     a
        add     #>$7fffff,a
        move    a,x:(r1)+               ; ring 2: 1 - lpAmt  (-1 .. 1)
        move    (r1)+                   ; round to ring 0
; pole A (offset 0 / 6)
        move    x:(r3),x0               ; hp state
        move    x:(r1)+,y1
        mpy     x0,y1,a
        move    x1,x0
        move    x:(r1)+,y1
        mac     x0,y1,a
        mac     x0,y1,a                 ; s' = s (1 - amt) + x amt
        move    a,x:(r3)
        move    x1,b
        sub     a,b                     ; x - s'
        move    b,x1
        move    x:(r5),x0               ; lp state
        move    x:(r1)+,y1
        mpy     x0,y1,a
        move    x1,x0
        move    x:(r1)+,y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r5)
        move    a,x1                    ; x = s'
; the o1 pair (B or C)
        move    n4,n3
        move    n4,n5
        move    x:(r3+n3),x0
        move    x:(r1)+,y1
        mpy     x0,y1,a
        move    x1,x0
        move    x:(r1)+,y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r3+n3)
        move    x1,b
        sub     a,b
        move    b,x1
        move    x:(r5+n5),x0
        move    x:(r1)+,y1
        mpy     x0,y1,a
        move    x1,x0
        move    x:(r1)+,y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r5+n5)
        move    a,x1
; the o2 pair (D, E or F)
        move    n6,n3
        move    n6,n5
        move    x:(r3+n3),x0
        move    x:(r1)+,y1
        mpy     x0,y1,a
        move    x1,x0
        move    x:(r1)+,y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r3+n3)
        move    x1,b
        sub     a,b
        move    b,x1
        move    x:(r5+n5),x0
        move    x:(r1)+,y1
        mpy     x0,y1,a
        move    x1,x0
        move    x:(r1)+,y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r5+n5)
        move    a,x0                    ; x = s'
        move    x:(r7+$29),y1           ; trim/2
        mpy     x0,y1,a
        asl     #$1,a,a                 ; out = x trim
        move    #>$ffffff,m1
        rts

; ---- fs_lcore: the ladder's per-channel core (LADR) ----------
; In: b = x, r1 -> this channel's seven-word stream (G^3(1-G) G^2(1-G)
; G(1-G) 1-G k/4 d/2 G'), r3 -> the channel's four halved states. Out:
; wetA = y4 in a. Straight-line, no control transfer (cycle_count.py's rule
; for a loop callee); clobbers x0 x1 y0 y1 a b r1 r3 n3.
fs_lcore:
; S/8 = (1-G)(G^3 s0 + G^2 s1 + G s2 + s3)/8 with the states at s/2: sum/4
        move    x:(r3)+,x0              ; s0/2
        move    x:(r1)+,y1              ; G^3(1-G)
        mpy     x0,y1,a
        move    x:(r3)+,x0              ; s1/2
        move    x:(r1)+,y1              ; G^2(1-G)
        mac     x0,y1,a
        move    x:(r3)+,x0              ; s2/2
        move    x:(r1)+,y1              ; G(1-G)
        mac     x0,y1,a
        move    x:(r3),x0               ; s3/2
        move    x:(r1)+,y1              ; 1-G
        move    #$3,n3
        mac     x0,y1,a                 ; S/2
        move    (r3)-n3                 ; back to s0
        asr     #$2,a,a                 ; S/8, <= 0.6
        move    a,x0
; u = (x - k S) d: k S = 32 (k/4)(S/8); the accumulator holds the sum
        move    x:(r1)+,y1              ; k/4
        mpy     x0,y1,a                 ; (k/4)(S/8)
        asl     #$5,a,a                 ; k S
        sub     a,b                     ; x - k S (b = x from the caller)
        asr     #$5,b,b                 ; /32, <= 0.6
        move    b,x0
        move    x:(r1)+,y1              ; d/2
        mpy     x0,y1,a                 ; (x - k S) d / 64
        asl     #$5,a,a                 ; u/2
        move    a,x1                    ; v/2 (limited: u within +-2)
        move    x:(r1)+,y1              ; G' for the four stages
; stage 0: y/2 = G'(v-s)/2 + s/2 ; s'/2 = y - s/2  (x1 = v/2 in, y/2 out)
        move    x:(r3),y0               ; s/2
        move    x1,a                    ; v/2
        sub     y0,a                    ; (v - s)/2
        asr     #$1,a,a                 ; (v - s)/4
        move    a,x0
        mpy     x0,y1,a                 ; G'(v - s)/4
        asl     #$1,a,a                 ; G'(v - s)/2
        add     y0,a                    ; y/2
        move    a,x1                    ; the next stage's v/2 (limited)
        asl     #$1,a,a                 ; y
        sub     y0,a                    ; s'/2 = y - s/2
        move    a,x:(r3)+               ; limited: s' within +-2
; stage 1: y/2 = G'(v-s)/2 + s/2 ; s'/2 = y - s/2  (x1 = v/2 in, y/2 out)
        move    x:(r3),y0               ; s/2
        move    x1,a                    ; v/2
        sub     y0,a                    ; (v - s)/2
        asr     #$1,a,a                 ; (v - s)/4
        move    a,x0
        mpy     x0,y1,a                 ; G'(v - s)/4
        asl     #$1,a,a                 ; G'(v - s)/2
        add     y0,a                    ; y/2
        move    a,x1                    ; the next stage's v/2 (limited)
        asl     #$1,a,a                 ; y
        sub     y0,a                    ; s'/2 = y - s/2
        move    a,x:(r3)+               ; limited: s' within +-2
; stage 2: y/2 = G'(v-s)/2 + s/2 ; s'/2 = y - s/2  (x1 = v/2 in, y/2 out)
        move    x:(r3),y0               ; s/2
        move    x1,a                    ; v/2
        sub     y0,a                    ; (v - s)/2
        asr     #$1,a,a                 ; (v - s)/4
        move    a,x0
        mpy     x0,y1,a                 ; G'(v - s)/4
        asl     #$1,a,a                 ; G'(v - s)/2
        add     y0,a                    ; y/2
        move    a,x1                    ; the next stage's v/2 (limited)
        asl     #$1,a,a                 ; y
        sub     y0,a                    ; s'/2 = y - s/2
        move    a,x:(r3)+               ; limited: s' within +-2
; stage 3: y/2 = G'(v-s)/2 + s/2 ; s'/2 = y - s/2  (x1 = v/2 in, y/2 out)
        move    x:(r3),y0               ; s/2
        move    x1,a                    ; v/2
        sub     y0,a                    ; (v - s)/2
        asr     #$1,a,a                 ; (v - s)/4
        move    a,x0
        mpy     x0,y1,a                 ; G'(v - s)/4
        asl     #$1,a,a                 ; G'(v - s)/2
        add     y0,a                    ; y/2
        move    a,x1                    ; the next stage's v/2 (limited)
        asl     #$1,a,a                 ; y
        sub     y0,a                    ; s'/2 = y - s/2
        move    a,x:(r3)+               ; limited: s' within +-2
; wetA = y4 = 2 * (y/2), in a for the caller's limiting store
        move    x1,a
        asl     #$1,a,a
        rts

; ===========================================================================
; BYPASS: frames untouched -- with no sends there is nothing to do at all
; ===========================================================================
fs_bypass:
        rts

