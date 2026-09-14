; ---------------------------------------------------------------------------
; SPECTRUM -- two filters, four routings, one modulation, two sends.
;
; Insert contract (modules/ripple/ripple_svf.asm): frames in place at
; x:(r0)/x:(r0+n0), knobs from r6, state in this instance's r7 block. PLUS
; the bus-client contract from modules/send/send_client.asm: the PROCESSED
; frames are summed to mono and added into the REVERB and DELAY accumulators
; at this block's write offset, and the instance registers in the per-block
; client count -- ONLY when its send knob is non-zero.
;
; ---- signal ---------------------------------------------------------------
;   A    = SVF(x, f, damp): lp / bp / hp taps              FREQ RES MODE   (DRV retired 13 Sep 2026)
;   wetA = kLP*lp + kBP*bp + kHP*hp                        (MODE, per block)
;   yB   = sel ? wetA : x                                  (ROUT, per block)
;   B    = LP2_wdth( HP2_base( yB ) )                      BASE WDTH
;   out  = kA*wetA + kB*B + kR*(2*wetA*B)                  (ROUT, per block)
;   f    = fA + kFM*B_prev  (clamped)                      (FM only)
;   fA   = law( FREQ + (DPTH-64)/64 * mod )                mod: ENV/LFO/BOTH
; NOTCH is kLP = kHP = 1 (lp + hp = x - damp*bp). VOWEL is a three-formant
; bank morphed across five vowels by FREQ. LADR (13 Sep 2026) is the linear
; zero-delay Moog ladder, 24 dB/oct, the loop's third alternative.
;
; ---- NO HOUSEKEEPING, by design ------------------------------------------
; The election (SEND's bus_dohk) is for FX2 participants. An FX1 instance on
; track 5 runs BEFORE that track's FX2 instance, and position 0 (r7 = 0x6200)
; housekeeps unconditionally -- so an FX1 participant that also elected would
; flip the rotation TWICE in the first block, which leaves core 1's private
; tracking one step behind forever (the R25 metallic). This station reads the
; rotation and writes; it never flips. On core 0 its contribution therefore
; lands in the buffer written LAST block (it runs before the flip), which is
; read one block sooner than everyone else's -- 16 samples less bus latency
; and nothing lost: that buffer was cleared two blocks ago and is read next.
;
; ---- r7 slots -------------------------------------------------------------
;   $20 fA (per block, post-modulation)   $21 damp          $22 (free; was DRV's g4)
;   $23 kLP  $24 kBP  $25 kHP              $26 kA  $27 kB  $28 kR  $29 sel
;   $2a cHP  $2b cLP  $2c kFM              $2d bypass flag
;   $30 FX2-slot flag (set at init: 1 = this instance is on FX2, dry)
;   $31 LFO phase (PERSISTENT, masked)     $32 env (PERSISTENT, clamped)
;   $34/$35 SVF lp/bp L   $36/$37 SVF lp/bp R                 (PERSISTENT)
;   $38..$3b B poles L: hp1 hp2 lp1 lp2    $3c..$3f R         (PERSISTENT)
;   $19/$1a B_out previous sample L/R (the FM source)         (PERSISTENT)
;   $1b wetA  $1c f this sample  $1d x / yB park  $1e peak (this block, so
;   at decode time LAST block's)  $1f f ceiling (per block)
;   $46 fall  $47 lfo inc  $49 lfo / frac park  $4a..$4d VOWEL picks
;   ⚠️ EVERY SLOT THE SAMPLE LOOP TOUCHES IS BELOW $40: an r7-indexed move
;   with a displacement past 63 takes the two-word long form, and the loop
;   priced 30 words dearer with these at $40..$4f (3 Sep 2026). Per-block
;   slots may sit high; per-sample ones may not. ⚠️ Until 14 Sep 2026 that
;   was only half true: dsp_asm emitted the two-word form for EVERY
;   displacement (the one-word form did not exist in the assembler), so
;   the sub-$40 slots cost 2 words each as well; the 30-word difference was
;   real but came from elsewhere. Since 14 Sep the assembler emits the
;   chip's one-word form for -64..63 with a data-ALU register, and the
;   rule above holds as written.
; Persistent states are bounded by the limited stores or masked on use;
; nothing here ever becomes an address except the bus pointers, which come
; masked exactly as SEND's are.
;
; Every mpy is `mpy x0,y1` (the known-signed encoding) except the send taps,
; which are SEND's `mpy x1,y1` / `mpy x1,y0` with a non-negative level in the
; second operand -- the one condition under which that order is safe. The FM
; clamp and the env max are cmp + ONE Tcc with nothing between (the flag
; trap).
; ---------------------------------------------------------------------------

init:
; ROTINIT
; ---- FX1 ONLY (12 Sep 2026): the allocator base decides, at init --------
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
; ⚠️ INIT MUST PRESERVE r1: the stock FX1 dispatcher keeps the effect id in
; r1 across `jsr init` and indexes PROC_TABLE with it afterwards (P:0x4c8..
; 0x4d7, disassembled 13 Sep 2026 under the ColdFire port). Zeroing through
; r1 here returned r1 = r7+24, the proc lookup read garbage, `jsr (r2)`
; landed on P:0 = the reset vector, and image 99 hung every core that loaded
; a Spectrum on FX1 -- at load, before a frame. dsp_host calls init and proc
; itself and never reads r1 between them, which is why no gate saw it. r5 is
; free at init (the tables load it later); tools/verify/verify_initregs.py
; now refuses any module init that writes r1.
; ---- EVERY PERSISTENT SLOT IS ZEROED HERE (14 Sep 2026) -------------------
; $00..$3f in one loop: the VOWL bank's states and coefficient slots
; ($00..$17), B_prev ($19/$1a), the parks, the peak ($1e), the LFO phase
; ($31), the env ($32), the SVF states ($34..$37) and FILTER B's poles
; ($38..$3f). The loop used to stop at $17, and a block holds whatever the
; effect before it left there: on the unit (never under the port, which
; boots zeroed RAM) filter B's two HP poles at cHP = 0 are FROZEN, so
; hp2 = yB - h2 subtracted a stale h2 from every sample forever -- a DC
; offset of up to full scale on a station's output, invisible in an
; AC-coupled capture, that the master's compressor makeup then clipped on
; one channel ("R collapses above COMP 40", 13-14 Sep 2026;
; docs/remixer/FAILURE_MODES.md). tools/verify/verify_dirtystate.py renders
; every module from a garbage block and refuses any output from silence.
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
        rts

proc:
        move    x:(r7+$30),a           ; an FX2 slot: dry, nothing written
        tst     a
        bne     fs_end
; (the bus section -- split-aware frame offset, the rotation latch, the registration
; and the r1/r2 accumulator pointers -- left with the sends, 12 Sep 2026: the
; stations have carried no send since the one-aux rig of 7 Sep, and the ~70
; words and ~10 cycles a block it cost bought nothing. The station is no
; longer a bus client: Harness(bus_client=False).)
; ===========================================================================
; PER-BLOCK KNOB DECODE
; ===========================================================================
; damp = (0.998 - RES * 0.587)^4   -- base linear in RES, then squared twice,
; so the resonant PEAK is close to linear in dB across the dial: ~0.8 / 5.5 /
; 12 / 20 / 30 dB at RES 0 / 32 / 64 / 96 / 127. Ripple's linear damp
; (0.992 - RES * 0.969, the law until 12 Sep 2026) measured 0.8 / 2.7 / 5.7 /
; 11.3 / 29.5 dB on noise: 18 of the 29 dB lived in the top quarter of the
; dial (tools/harness/station_laws.py). RES 0 is unchanged (0.998^4 = 0.992).
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
; (DRV retired 13 Sep 2026: page-2 slot 6 is blank; Character owns drive. The
; per-sample stage was x * (0.25 + DRV*0.75) * 4 -- exactly x at DRV 0.)
; cHP = BASE^2 * 0.5 ;  cLP = WDTH^2 * 1.0 + 0.002  (one-pole coefficients)
; cLP's scale was 0.75 until 12 Sep 2026: WDTH 127 then sat at 0.74 (about
; 7 kHz per pole, 12 dB/oct above it), so "open" lost 5 dB at 10 kHz and 8 dB
; at 15 kHz in EVERY live setting -- measured on noise, station_laws.py --
; and only the all-defaults bypass was flat. At 1.0 WDTH 127 is 0.986: a
; corner near 30 kHz per pole, flat within 0.15 dB at 10 kHz.
        move    x:(r6+$2),x0
        move    x:(r6+$2),y1
        mpy     x0,y1,a
        move    a,x0
        move    #>$400000,y1
        mpy     x0,y1,a
        move    a,x:(r7+$2a)
        move    x:(r6+$3),x0
        move    x:(r6+$3),y1
        mpy     x0,y1,a
        move    a,x0
        move    #>$7fffff,y1            ; x 1.0
        mpy     x0,y1,a
        add     #>$4189,a
        move    a,x:(r7+$2b)
; RATE (slot 10 KNOB of r6+$e): lfo inc = RATE^2 * $7000 + $100 per block
; (~0.08..9 Hz); fall = $7fe000 - RATE * $1e00 (~370 ms .. ~3 ms release)
        move    x:(r6+$e),a
        and     #>$7f0000,a
        move    a1,x0
        move    x0,a
        move    a,x0
        move    a,y1
        mpy     x0,y1,a
        move    a,x0
        move    #>$7000,y1
        mpy     x0,y1,a
        add     #>$100,a
        move    a,x:(r7+$47)            ; lfo inc
        move    x:(r6+$e),a
        and     #>$7f0000,a
        move    a1,x0
        move    x0,a
        move    a,x0
        move    #>$f0000,y1
        mpy     x0,y1,a                 ; RATE * $1e00 in Q23
        neg     a
        add     #>$7fe000,a
        move    a,x:(r7+$46)            ; fall

; ---- LFO: phase += inc, triangle -> bipolar Q23 ---------------------------
        move    x:(r7+$31),a
        move    x:(r7+$47),x0
        add     x0,a
        and     #>$7fffff,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$31)
        move    #>$400000,x0
        sub     x0,a
        abs     a                       ; 0 .. $400000
        move    #>$200000,x0
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

; ---- SRC (slot 11 select of r6+$e): mod = env | lfo | (env+lfo)/2 ---------
        move    x:(r6+$e),a
        and     #>$ff00,a
        move    a1,x0
        move    x0,a
        asl     #$8,a,a
        move    #>$10000,x0
        cmp     x0,a
        beq     fs_slfo
        move    #>$20000,x0
        cmp     x0,a
        beq     fs_sboth
        move    x:(r7+$32),a            ; ENV (and anything unexpected)
        bra     fs_smod
fs_slfo:
        move    x:(r7+$49),a
        bra     fs_smod
fs_sboth:
        move    x:(r7+$32),a
        move    x:(r7+$49),x0
        add     x0,a
        asr     #$1,a,a
fs_smod:
; ---- DPTH (slot 8 KNOB of r6+$d): depth = (DPTH - 64)/64, bipolar ---------
        move    a,x1                    ; mod
        move    x:(r6+$d),a
        and     #>$7f0000,a
        move    a1,x0
        move    x0,a
        move    #>$400000,x0
        sub     x0,a                    ; (DPTH-64)/128
        asl     #$1,a,a                 ; (DPTH-64)/64, -1 .. +1
        move    a,x0
        move    x1,y1
        mpy     x0,y1,a                 ; depth * mod  (x0 signed, y1 signed)
        move    x:(r6+$0),x0            ; FREQ
        add     x0,a                    ; FREQm
        move    #>$0,x0
        tmi     x0,a                    ; clamp below at 0
        move    #>$7f0000,x0
        cmp     x0,a
        tgt     x0,a                    ; clamp above at 127/128
; g2 = table(FREQm): an EXPONENTIAL taper, 24 Hz..15 kHz, one octave per
; ~13.8 detents (13 Sep 2026: the SEM core has no stable ceiling, so the top
; went from 7.2 kHz, the Chamberlin form's limit, to 15 kHz), read from the
; 33-word P table the manifest declares
; (DspSection.ptable; the build places it before this code and rewrites the
; literal below) and interpolated linearly: idx = FREQm >> 18 (0..31),
; frac = the 18 bits under it as Q23. Until 12 Sep 2026 the law was
; 0.984 * FREQm^2 + 0.0034 -- half the dial above 2 kHz on noise, and the
; loop's centroid on the drum loop barely moved from FREQ 24 to 56.
; AGU settle: r5/n5 are written two instructions before they address.
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
; ---- the cutoff RAMP (13 Sep 2026): dg = (g2 - g2run)/16 per block, added
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
        move    #>$100000,y1            ; 1/8
        move    y1,a                    ; a clean load: a0 = 0 for the divide
        andi    #$fe,ccr                ; carry clear
        rep     #$18
        div     x0,a                    ; 24 quotient bits land in a0
        move    a0,x0
        move    x0,x:(r7+$33)           ; d

; ---- ROUT (slot 9 select of r6+$d): sel, kA, kB, kR, kFM -------------------
        clr     a
        move    a,x:(r7+$29)            ; sel = 0
        move    a,x:(r7+$26)            ; kA
        move    a,x:(r7+$27)            ; kB
        move    a,x:(r7+$28)            ; kR
        move    a,x:(r7+$2c)            ; kFM
        move    x:(r6+$d),a
        and     #>$ff00,a
        move    a1,x0
        move    x0,a
        asl     #$8,a,a
        move    #>$10000,x0
        cmp     x0,a
        beq     fs_rpar
        move    #>$20000,x0
        cmp     x0,a
        beq     fs_rring
        move    #>$30000,x0
        cmp     x0,a
        beq     fs_rfm
        move    #>$1,x0                 ; SER (and anything unexpected):
        move    x0,x:(r7+$29)           ; B is fed A, out = B
        move    #>$7fffff,x0
        move    x0,x:(r7+$27)
        bra     fs_rdone
fs_rpar:
        move    #>$400000,x0            ; PAR: out = (A + B) / 2
        move    x0,x:(r7+$26)
        move    x0,x:(r7+$27)
        bra     fs_rdone
fs_rring:
        move    #>$7fffff,x0            ; RING: out = 2 * A * B
        move    x0,x:(r7+$28)
        bra     fs_rdone
fs_rfm:
        move    #>$7fffff,x0            ; FM: out = A, f modulated by B
        move    x0,x:(r7+$26)
        move    #>$400000,x0            ; kFM = 0.5 (0.25 was "a bit little" by ear, 12 Sep 2026)
        move    x0,x:(r7+$2c)
fs_rdone:

; ---- MODE (slot 7 select of r6+$c): tap coefficients; VOWL runs the bank ---
        clr     a
        move    a,x:(r7+$2d)            ; the SVF alternative unless VOWL says so
        move    a,x:(r7+$23)
        move    a,x:(r7+$24)
        move    a,x:(r7+$25)
        move    #>$7fffff,x0
        move    x:(r6+$c),a
        and     #>$ff00,a
        move    a1,x1
        move    x1,a
        asl     #$8,a,a                 ; mode << 16
        move    #>$10000,x1
        cmp     x1,a
        beq     fs_mbp
        move    #>$20000,x1
        cmp     x1,a
        beq     fs_mhp
        move    #>$30000,x1
        cmp     x1,a
        beq     fs_mntch
        move    #>$40000,x1
        cmp     x1,a
        beq     fs_mvowl
        move    #>$50000,x1
        cmp     x1,a
        beq     fs_mladr
        move    x0,x:(r7+$23)           ; LP, and anything unexpected
        bra     fs_mdone
fs_mbp:
        move    x0,x:(r7+$24)
        bra     fs_mdone
fs_mhp:
        move    x0,x:(r7+$25)
        bra     fs_mdone
fs_mntch:
        move    x0,x:(r7+$23)
        move    x0,x:(r7+$25)
        bra     fs_mdone
fs_mvowl:
; ---- VOWL (13 Sep 2026): three parallel constant-peak-gain resonators
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
        asl     #$12,a,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$49)            ; frac (the lfo park is dead by now)
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
        move    #>33,n5
        move    (r5)+n5                 ; r5 = COS_TABLE[idx][0] (33 words past G2)
        move    #>3,n5
; formant 0: cw = CW[idx][0] + frac*(CW[idx+1][0] - CW[idx][0]) (p:(r5)+n5
; reads the first and steps to the next vowel, p:(r5)-n5 reads it and steps
; back; (r5)+ moves to the next formant); R' = R0 + e0*RES narrows the band
; with RES; m1 = R'*cw = -a1/2, a2 = R'^2, b0 = (1 - a2)/2.
        move    p:(r5)+n5,y0            ; CW[idx][0]
        move    p:(r5)-n5,b             ; CW[idx+1][0]
        move    (r5)+
        move    y0,a
        sub     a,b                     ; diff
        move    b,x0
        move    x:(r7+$49),y1           ; frac
        mpy     x0,y1,a
        add     y0,a                    ; cw
        move    a,x1
        move    x:(r6+$1),x0            ; RES/128
        move    #>$00bc7a,y1       ; e0 = 0.9*(1 - R0)
        mpy     x0,y1,a
        add     #>$7f2e95,a        ; R0 = exp(-pi*90/fs)
        move    a,y1                    ; R' (> 0: the SEND-safe second operand)
        mpy     x1,y1,b                 ; m1 = cw*R'
        move    b,x:(r7+$10)
        move    a,x0
        mpy     x0,y1,b                 ; a2 = R'^2
        move    b,x:(r7+$13)
        asr     #$1,b,b
        neg     b
        add     #>$400000,b             ; b0 = 1/2 - a2/2
        move    b,x:(r7+$16)
; formant 1: cw = CW[idx][1] + frac*(CW[idx+1][1] - CW[idx][1]) (p:(r5)+n5
; reads the first and steps to the next vowel, p:(r5)-n5 reads it and steps
; back; (r5)+ moves to the next formant); R' = R1 + e1*RES narrows the band
; with RES; m1 = R'*cw = -a1/2, a2 = R'^2, b0 = (1 - a2)/2.
        move    p:(r5)+n5,y0            ; CW[idx][1]
        move    p:(r5)-n5,b             ; CW[idx+1][1]
        move    (r5)+
        move    y0,a
        sub     a,b                     ; diff
        move    b,x0
        move    x:(r7+$49),y1           ; frac
        mpy     x0,y1,a
        add     y0,a                    ; cw
        move    a,x1
        move    x:(r6+$1),x0            ; RES/128
        move    #>$00e632,y1       ; e1 = 0.9*(1 - R1)
        mpy     x0,y1,a
        add     #>$7f003a,a        ; R1 = exp(-pi*110/fs)
        move    a,y1                    ; R' (> 0: the SEND-safe second operand)
        mpy     x1,y1,b                 ; m1 = cw*R'
        move    b,x:(r7+$11)
        move    a,x0
        mpy     x0,y1,b                 ; a2 = R'^2
        move    b,x:(r7+$14)
        asr     #$1,b,b
        neg     b
        add     #>$400000,b             ; b0 = 1/2 - a2/2
        move    b,x:(r7+$17)
; formant 2: cw = CW[idx][2] + frac*(CW[idx+1][2] - CW[idx][2]) (p:(r5)+n5
; reads the first and steps to the next vowel, p:(r5)-n5 reads it and steps
; back; (r5)+ moves to the next formant); R' = R2 + e2*RES narrows the band
; with RES; m1 = R'*cw = -a1/2, a2 = R'^2, b0 = (1 - a2)/2.
        move    p:(r5)+n5,y0            ; CW[idx][2]
        move    p:(r5)-n5,b             ; CW[idx+1][2]
        move    (r5)+
        move    y0,a
        sub     a,b                     ; diff
        move    b,x0
        move    x:(r7+$49),y1           ; frac
        mpy     x0,y1,a
        add     y0,a                    ; cw
        move    a,x1
        move    x:(r6+$1),x0            ; RES/128
        move    #>$0162ff,y1       ; e2 = 0.9*(1 - R2)
        mpy     x0,y1,a
        add     #>$7e758f,a        ; R2 = exp(-pi*170/fs)
        move    a,y1                    ; R' (> 0: the SEND-safe second operand)
        mpy     x1,y1,b                 ; m1 = cw*R'
        move    b,x:(r7+$12)
        move    a,x0
        mpy     x0,y1,b                 ; a2 = R'^2
        move    b,x:(r7+$15)
        asr     #$1,b,b
        neg     b
        add     #>$400000,b             ; b0 = 1/2 - a2/2
        move    b,x:(r7+$18)
        bra     fs_mdone
fs_mladr:
; ---- LADR (13 Sep 2026): the Moog transistor ladder, the LINEAR zero-delay
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
; $10 G  $11 G^2  $12 G^3  $13 k/4  $14 d/2  $15 dG  $16 Grun.
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
        move    x0,x:(r7+$10)
        move    x0,y1
        mpy     x0,y1,a                 ; G^2
        move    a,x:(r7+$11)
        move    a,x0
        mpy     x0,y1,a                 ; G^3
        move    a,x:(r7+$12)
        move    x:(r7+$11),x0
        move    x:(r7+$11),y1
        mpy     x0,y1,a                 ; G^4
        move    a,x0
        move    x:(r7+$13),y1           ; k/4
        mpy     x0,y1,a                 ; (k/4) G^4
        asl     #$1,a,a                 ; 2 (k/4) G^4 = k G^4 / 2  (<= 0.34)
        add     #>$400000,a             ; den = 1/2 + k G^4 / 2
        move    a,x0
        move    #>$200000,a             ; num = 1/4: d/2 = (1/4)/den, <= 1/2
        andi    #$fe,ccr
        rep     #$18
        div     x0,a
        move    a0,x0
        move    x0,x:(r7+$14)           ; d/2
        move    x:(r7+$10),a            ; G
        move    x:(r7+$16),x0           ; Grun, where the last block ended
        sub     x0,a
        asr     #$4,a,a
        move    a,x:(r7+$15)            ; dG
fs_mdone:

; ---- BYPASS: the defaults are a bit-exact passthrough ---------------------
; FREQ 127, RES 0, BASE 0, WDTH 127, DPTH 64, MODE LP, ROUT SER. Every
; part that ever chose stock FILTER runs this on FX1 after the flash, so the
; neutral block copies nothing and only does the sends.
        clr     b
        move    x:(r6+$0),a
        move    #>$7f0000,x0
        cmp     x0,a
        bne     fs_live
        move    x:(r6+$1),a
        tst     a
        bne     fs_live
        move    x:(r6+$2),a
        tst     a
        bne     fs_live
        move    x:(r6+$3),a
        cmp     x0,a
        bne     fs_live
        move    x:(r6+$c),a             ; the MODE select (slot 6's knob field is
        and     #>$ff00,a               ; blank since DRV went, 13 Sep 2026)
        move    a1,x0
        move    x0,a
        tst     a
        bne     fs_live
        move    x:(r6+$d),a             ; DPTH knob field AND the ROUT select
        and     #>$7fff00,a
        move    a1,x0
        move    x0,a
        move    #>$400000,x0
        cmp     x0,a
        bne     fs_live
        bra     fs_bypass
fs_live:

; ===========================================================================
; THE SAMPLE LOOP -- one MODEFORK: the SEM SVF, or the VOWL bank; filter B
; and the mix are one straight-line callee both alternatives call per
; channel (13 Sep 2026). CYCLES_FORWARD_BRANCHES: the fork's dispatch is the
; only branch, and the pricer charges dispatch + the worst alternative.
; ===========================================================================
        move    #>$1,n0
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
; MODEFORK_MID -- alternative 1: the SEM zero-delay SVF, LP / BP / HP / NOTCH
; ===================== channel L =====================
        move    x:(r0),x0
        move    x0,x:(r7+$1d)           ; park x
; FM: g = clamp(g2run * (1 + kFM * B_prev)), d frozen for the block
        move    x:(r7+$19),x0           ; B_prev L
        move    x:(r7+$2c),y1           ; kFM (0 unless ROUT = FM)
        mpy     x0,y1,a                 ; kFM * B, +-0.5
        move    a,x0
        move    x:(r7+$2e),y1           ; g2run
        mpy     x0,y1,a                 ; g2run * kFM * B: MULTIPLICATIVE FM,
        move    x:(r7+$2e),x0           ; so g stays positive by construction
        add     x0,a                    ; g = g2run * (1 + kFM * B)
        move    #>$7f0000,x0            ; g2 < 1 (the halved g's own rail)
        cmp     x0,a
        tgt     x0,a
        move    a,x:(r7+$1c)            ; g2 this sample
        move    x:(r7+$1d),x1           ; x (DRV retired: x_d == x)
; t8 = (x_d - (2R+g)*s0 - s1)/8, pre-scaled so nothing clamps before hp
        move    x:(r7+$34),x0           ; s0
        move    x:(r7+$1f),y1           ; c4 = (R + g2)/2
        mpy     x0,y1,a
        asl     #$2,a,a                 ; (2R + g) * s0
        move    x:(r7+$35),x0           ; s1
        add     x0,a
        move    x1,b
        sub     a,b                     ; t
        asr     #$3,b,b
        move    b,x0                    ; t8, |t8| <= 0.63
; hp = 8 * d * t8  (the ZDF's implicit solve)
        move    x:(r7+$33),y1           ; d
        mpy     x0,y1,a
        asl     #$3,a,a
        move    a,x0                    ; hp, limited -- the resonance clamp
        move    a,y0                    ; hp for the taps
; p = 2*g*hp ; bp = s0 + p ; s0' = bp + p  (trapezoidal integrator)
        move    x:(r7+$1c),y1           ; g2
        mpy     x0,y1,b
        asl     #$1,b,b                 ; p = g*hp
        move    x:(r7+$34),a
        add     b,a                     ; bp
        move    a,x1                    ; bp, limited
        add     b,a
        move    a,x:(r7+$34)            ; s0'
; q = 2*g*bp ; lp = s1 + q ; s1' = lp + q
        move    x1,x0
        mpy     x0,y1,b
        asl     #$1,b,b                 ; q = g*bp
        move    x:(r7+$35),a
        add     b,a                     ; lp
        move    a,x:(r7+$1b)            ; lp parked (limited)
        add     b,a
        move    a,x:(r7+$35)            ; s1'
; wetA = kBP*bp + kHP*hp + kLP*lp   (NOTCH = hp + lp)
        move    x1,x0
        move    x:(r7+$24),y1
        mpy     x0,y1,a
        move    y0,x0
        move    x:(r7+$25),y1
        mpy     x0,y1,b
        add     b,a
        move    x:(r7+$1b),x0
        move    x:(r7+$23),y1
        mpy     x0,y1,b
        add     b,a
        move    a,x:(r7+$1b)            ; wetA
; filter B and the mix (the shared callee); r3 -> this channel's B poles,
; n3 -> its B_prev from there
        move    r7,r3
        move    #>$38,n3
        move    (r3)+n3
        move    #>$ffffe1,n3
        bsr     fs_bmix
        move    a,x:(r0)                ; out L (limited)
; ===================== channel R =====================
        move    x:(r0+n0),x0
        move    x0,x:(r7+$1d)           ; park x
; FM: g = clamp(g2run * (1 + kFM * B_prev)), d frozen for the block
        move    x:(r7+$1a),x0           ; B_prev R
        move    x:(r7+$2c),y1           ; kFM (0 unless ROUT = FM)
        mpy     x0,y1,a                 ; kFM * B, +-0.5
        move    a,x0
        move    x:(r7+$2e),y1           ; g2run
        mpy     x0,y1,a                 ; g2run * kFM * B: MULTIPLICATIVE FM,
        move    x:(r7+$2e),x0           ; so g stays positive by construction
        add     x0,a                    ; g = g2run * (1 + kFM * B)
        move    #>$7f0000,x0            ; g2 < 1 (the halved g's own rail)
        cmp     x0,a
        tgt     x0,a
        move    a,x:(r7+$1c)            ; g2 this sample
        move    x:(r7+$1d),x1           ; x (DRV retired: x_d == x)
; t8 = (x_d - (2R+g)*s0 - s1)/8, pre-scaled so nothing clamps before hp
        move    x:(r7+$36),x0           ; s0
        move    x:(r7+$1f),y1           ; c4 = (R + g2)/2
        mpy     x0,y1,a
        asl     #$2,a,a                 ; (2R + g) * s0
        move    x:(r7+$37),x0           ; s1
        add     x0,a
        move    x1,b
        sub     a,b                     ; t
        asr     #$3,b,b
        move    b,x0                    ; t8, |t8| <= 0.63
; hp = 8 * d * t8  (the ZDF's implicit solve)
        move    x:(r7+$33),y1           ; d
        mpy     x0,y1,a
        asl     #$3,a,a
        move    a,x0                    ; hp, limited -- the resonance clamp
        move    a,y0                    ; hp for the taps
; p = 2*g*hp ; bp = s0 + p ; s0' = bp + p  (trapezoidal integrator)
        move    x:(r7+$1c),y1           ; g2
        mpy     x0,y1,b
        asl     #$1,b,b                 ; p = g*hp
        move    x:(r7+$36),a
        add     b,a                     ; bp
        move    a,x1                    ; bp, limited
        add     b,a
        move    a,x:(r7+$36)            ; s0'
; q = 2*g*bp ; lp = s1 + q ; s1' = lp + q
        move    x1,x0
        mpy     x0,y1,b
        asl     #$1,b,b                 ; q = g*bp
        move    x:(r7+$37),a
        add     b,a                     ; lp
        move    a,x:(r7+$1b)            ; lp parked (limited)
        add     b,a
        move    a,x:(r7+$37)            ; s1'
; wetA = kBP*bp + kHP*hp + kLP*lp   (NOTCH = hp + lp)
        move    x1,x0
        move    x:(r7+$24),y1
        mpy     x0,y1,a
        move    y0,x0
        move    x:(r7+$25),y1
        mpy     x0,y1,b
        add     b,a
        move    x:(r7+$1b),x0
        move    x:(r7+$23),y1
        mpy     x0,y1,b
        add     b,a
        move    a,x:(r7+$1b)            ; wetA
; filter B and the mix (the shared callee); r3 -> this channel's B poles,
; n3 -> its B_prev from there
        move    r7,r3
        move    #>$3c,n3
        move    (r3)+n3
        move    #>$ffffde,n3
        bsr     fs_bmix
        move    a,x:(r0+n0)                ; out R (limited)
        bra     fs_join
; MODEFORK_MID -- alternative 2: VOWL, the three-formant bank
fs_v_or_l:
        move    #>$1,x0
        cmp     x0,a
        bne     fs_ladr                 ; 2: the ladder (the third alternative)
fs_vowl:
; ===================== channel L =====================
        move    x:(r0),x0
        move    x0,x:(r7+$1d)           ; park x
        move    x0,x1                   ; x (DRV retired: x_d == x)
; dx/2 = (x_d - x2)/2, shared by the three resonators; then x2 <- x1 <- x_d
        move    x:(r7+$01),x0           ; x2
        move    x1,a
        sub     x0,a
        asr     #$1,a,a
        move    a,x:(r7+$1b)            ; dx/2, parked (|.| <= 1)
        move    x:(r7+$00),x0
        move    x0,x:(r7+$01)
        move    x1,x:(r7+$00)
; formant 0: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x:(r7+$1b),x0
        move    x:(r7+$16),y1           ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r7+$02),x0           ; y1
        move    x:(r7+$10),y1           ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x:(r7+$03),x0           ; y2
        move    x:(r7+$13),y1           ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    x:(r7+$02),x0
        move    x0,x:(r7+$03)           ; y2 <- y1
        move    a,x:(r7+$02)            ; y1 <- y (limited)
        move    a,x0                    ; y, limited
        move    #>$400000,y1          ; the formant's gain, halved
        mpy     x0,y1,a
        move    a,x:(r7+$1c)            ; the sum so far (halved)
; formant 1: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x:(r7+$1b),x0
        move    x:(r7+$17),y1           ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r7+$04),x0           ; y1
        move    x:(r7+$11),y1           ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x:(r7+$05),x0           ; y2
        move    x:(r7+$14),y1           ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    x:(r7+$04),x0
        move    x0,x:(r7+$05)           ; y2 <- y1
        move    a,x:(r7+$04)            ; y1 <- y (limited)
        move    a,x0                    ; y, limited
        move    #>$200000,y1          ; the formant's gain, halved
        mpy     x0,y1,b
        move    x:(r7+$1c),a
        add     b,a
        move    a,x:(r7+$1c)
; formant 2: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x:(r7+$1b),x0
        move    x:(r7+$18),y1           ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r7+$06),x0           ; y1
        move    x:(r7+$12),y1           ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x:(r7+$07),x0           ; y2
        move    x:(r7+$15),y1           ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    x:(r7+$06),x0
        move    x0,x:(r7+$07)           ; y2 <- y1
        move    a,x:(r7+$06)            ; y1 <- y (limited)
        move    a,x0                    ; y, limited
        move    #>$133333,y1          ; the formant's gain, halved
        mpy     x0,y1,b
        move    x:(r7+$1c),a
        add     b,a
        move    a,x:(r7+$1c)
; wetA = 2 * the halved sum (= y0 + 0.5*y1 + 0.3*y2), limited
        move    x:(r7+$1c),a
        asl     #$1,a,a
        move    a,x:(r7+$1b)            ; wetA
        move    r7,r3
        move    #>$38,n3
        move    (r3)+n3
        move    #>$ffffe1,n3
        bsr     fs_bmix
        move    a,x:(r0)                ; out L (limited)
; ===================== channel R =====================
        move    x:(r0+n0),x0
        move    x0,x:(r7+$1d)           ; park x
        move    x0,x1                   ; x (DRV retired: x_d == x)
; dx/2 = (x_d - x2)/2, shared by the three resonators; then x2 <- x1 <- x_d
        move    x:(r7+$09),x0           ; x2
        move    x1,a
        sub     x0,a
        asr     #$1,a,a
        move    a,x:(r7+$1b)            ; dx/2, parked (|.| <= 1)
        move    x:(r7+$08),x0
        move    x0,x:(r7+$09)
        move    x1,x:(r7+$08)
; formant 0: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x:(r7+$1b),x0
        move    x:(r7+$16),y1           ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r7+$0a),x0           ; y1
        move    x:(r7+$10),y1           ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x:(r7+$0b),x0           ; y2
        move    x:(r7+$13),y1           ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    x:(r7+$0a),x0
        move    x0,x:(r7+$0b)           ; y2 <- y1
        move    a,x:(r7+$0a)            ; y1 <- y (limited)
        move    a,x0                    ; y, limited
        move    #>$400000,y1          ; the formant's gain, halved
        mpy     x0,y1,a
        move    a,x:(r7+$1c)            ; the sum so far (halved)
; formant 1: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x:(r7+$1b),x0
        move    x:(r7+$17),y1           ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r7+$0c),x0           ; y1
        move    x:(r7+$11),y1           ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x:(r7+$0d),x0           ; y2
        move    x:(r7+$14),y1           ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    x:(r7+$0c),x0
        move    x0,x:(r7+$0d)           ; y2 <- y1
        move    a,x:(r7+$0c)            ; y1 <- y (limited)
        move    a,x0                    ; y, limited
        move    #>$200000,y1          ; the formant's gain, halved
        mpy     x0,y1,b
        move    x:(r7+$1c),a
        add     b,a
        move    a,x:(r7+$1c)
; formant 2: y = 2*b0*(dx/2) + 2*m1*y1 - a2*y2; then y2 <- y1 <- y
        move    x:(r7+$1b),x0
        move    x:(r7+$18),y1           ; b0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r7+$0e),x0           ; y1
        move    x:(r7+$12),y1           ; m1 = -a1/2
        mpy     x0,y1,b
        asl     #$1,b,b
        add     b,a
        move    x:(r7+$0f),x0           ; y2
        move    x:(r7+$15),y1           ; a2
        mpy     x0,y1,b
        sub     b,a                     ; y
        move    x:(r7+$0e),x0
        move    x0,x:(r7+$0f)           ; y2 <- y1
        move    a,x:(r7+$0e)            ; y1 <- y (limited)
        move    a,x0                    ; y, limited
        move    #>$133333,y1          ; the formant's gain, halved
        mpy     x0,y1,b
        move    x:(r7+$1c),a
        add     b,a
        move    a,x:(r7+$1c)
; wetA = 2 * the halved sum (= y0 + 0.5*y1 + 0.3*y2), limited
        move    x:(r7+$1c),a
        asl     #$1,a,a
        move    a,x:(r7+$1b)            ; wetA
        move    r7,r3
        move    #>$3c,n3
        move    (r3)+n3
        move    #>$ffffde,n3
        bsr     fs_bmix
        move    a,x:(r0+n0)                ; out R (limited)
        bra     fs_join
; MODEFORK_MID -- alternative 3: LADR, the linear zero-delay Moog ladder
fs_ladr:
; the per-sample ramp: Grun += dG (the ladder's g2run; found missing by the
; float comparison rendering silence, 13 Sep 2026 -- G' was 0 every sample)
        move    x:(r7+$16),a
        move    x:(r7+$15),x0
        add     x0,a
        move    a,x:(r7+$16)            ; limited: G never past the rail
; ===================== channel L =====================
        move    x:(r0),x0
        move    x0,x:(r7+$1d)           ; park x
; the ladder core (fs_lcore, one straight-line callee per channel, 13 Sep
; 2026: inline it overran payload A by 20 words): x0 = B_prev, r3 -> the
; four states; wetA lands in $1b
        move    x:(r7+$19),x0           ; B_prev
        move    r7,r3                   ; states s0..s3 at $00
        bsr     fs_lcore
        move    r7,r3
        move    #>$38,n3
        move    (r3)+n3
        move    #>$ffffe1,n3
        bsr     fs_bmix
        move    a,x:(r0)                ; out (limited)
; ===================== channel R =====================
        move    x:(r0+n0),x0
        move    x0,x:(r7+$1d)           ; park x
        move    x:(r7+$1a),x0           ; B_prev
        move    r7,r3
        move    #>$8,n3
        move    (r3)+n3                 ; states s0..s3 at $08
        bsr     fs_lcore
        move    r7,r3
        move    #>$3c,n3
        move    (r3)+n3
        move    #>$ffffde,n3
        bsr     fs_bmix
        move    a,x:(r0+n0)                ; out (limited)
; MODEFORK_END
fs_join:
        move    #>$2,n0                 ; LONG immediates, deliberately: the
        move    (r0)+n0                 ; short form `move #2,n0` assembled and
        move    #>$1,n0                 ; stepped ONE word per frame (3 Sep 2026)
fs_end:
        nop
        rts

; ---------------------------------------------------------------------------
; fs_bmix -- filter B (two HP poles at cHP, two LP poles at cLP) and the
; mix, for one channel. In: x:(r7+$1b) = wetA, x:(r7+$1d) = the parked x,
; r3 -> the channel's four B poles, (r3+n3) its B_prev (the FM source).
; Out: a = kA*wetA + kB*B + kR*(2*wetA*B), for the caller's limiting store.
; Straight-line (one Tcc, nothing between it and its tst): a loop callee.
; ---------------------------------------------------------------------------
fs_bmix:
; yB = sel ? wetA : x
        move    x:(r7+$1b),x1           ; wetA
        move    x:(r7+$29),b
        tst     b
        move    x:(r7+$1d),a
        tne     x1,a
        move    a,x:(r7+$1d)            ; yB
; two HP poles (HP = in - LP2(in)) at cHP
        move    x:(r3),b                ; h1
        sub     b,a                     ; yB - h1
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$2a),y1           ; cHP
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a                     ; h1'
        move    a,x:(r3)
        move    x:(r3+$1),b             ; h2
        sub     b,a                     ; h1' - h2
        asr     #$1,a,a
        move    a,x0
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a                     ; h2'
        move    a,x:(r3+$1)
        move    a,x0
        move    x:(r7+$1d),a
        sub     x0,a                    ; hp2 = yB - h2'
        move    a,x:(r7+$1d)            ; park hp2
; two LP poles at cLP
        move    x:(r3+$2),b             ; l1
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$2b),y1           ; cLP
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r3+$2)
        move    x:(r3+$3),b             ; l2
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r3+$3)             ; B_out = l2'
        move    a,x:(r3+n3)             ; B_prev for next sample's FM
; out = kA*wetA + kB*B + kR*(2*wetA*B)
        move    a,x0                    ; B_out
        move    x:(r7+$27),y1           ; kB
        mpy     x0,y1,a
        move    x:(r7+$1b),y1           ; wetA (signed x signed: the known-
        mpy     x0,y1,b                 ; signed order)
        asl     #$1,b,b
        move    b,x0
        move    x:(r7+$28),y1           ; kR
        mpy     x0,y1,b
        add     b,a
        move    x:(r7+$1b),x0           ; wetA
        move    x:(r7+$26),y1           ; kA
        mpy     x0,y1,b
        add     b,a
        rts

; ---- fs_lcore: the ladder's per-channel core (LADR, 13 Sep 2026) ----------
; In: x0 = B_prev, r3 -> the channel's four halved states, x parked at $1d,
; the block's G powers at $10..$12, k/4 at $13, d/2 at $14, Grun at $16.
; Out: wetA = y4 at $1b (and in a). Straight-line, no control transfer
; (cycle_count.py's rule for a loop callee); clobbers x0 x1 y0 y1 a b r3 n3.
fs_lcore:
; G' = clamp(Grun * (1 + kFM * B_prev)): FM as the SEM does it, d frozen
        move    x:(r7+$2c),y1           ; kFM (0 unless ROUT = FM)
        mpy     x0,y1,a                 ; kFM * B, +-0.5
        move    a,x0
        move    x:(r7+$16),y1           ; Grun
        mpy     x0,y1,a
        move    x:(r7+$16),x0
        add     x0,a                    ; G' = Grun * (1 + kFM * B)
        move    #>$7f0000,x0
        cmp     x0,a
        tgt     x0,a                    ; G' < 1
        move    a,x:(r7+$1c)            ; G' this sample
; S/8 = (G^3 s0 + G^2 s1 + G s2 + s3)/8 with the states at s/2: sum/4
        move    x:(r3)+,x0              ; s0/2
        move    x:(r7+$12),y1           ; G^3
        mpy     x0,y1,a
        move    x:(r3)+,x0              ; s1/2
        move    x:(r7+$11),y1           ; G^2
        mac     x0,y1,a
        move    x:(r3)+,x0              ; s2/2
        move    x:(r7+$10),y1           ; G
        mac     x0,y1,a
        move    x:(r3),x0               ; s3/2
        move    #>$3,n3
        add     x0,a                    ; S/2
        move    (r3)-n3                 ; back to s0
        asr     #$2,a,a                 ; S/8, <= 0.6
        move    a,x0
; u = (x - k S) d: k S = 32 (k/4)(S/8); the accumulator holds the sum
        move    x:(r7+$13),y1           ; k/4
        mpy     x0,y1,a                 ; (k/4)(S/8)
        asl     #$5,a,a                 ; k S
        move    x:(r7+$1d),b            ; x
        sub     a,b                     ; x - k S
        asr     #$5,b,b                 ; /32, <= 0.6
        move    b,x0
        move    x:(r7+$14),y1           ; d/2
        mpy     x0,y1,a                 ; (x - k S) d / 64
        asl     #$5,a,a                 ; u/2
        move    a,x1                    ; v/2 (limited: u within +-2)
        move    x:(r7+$1c),y1           ; G' for the four stages
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
; wetA = y4 = 2 * (y/2)
        move    x1,a
        asl     #$1,a,a
        move    a,x:(r7+$1b)            ; wetA (limited)
        rts

; ===========================================================================
; BYPASS: frames untouched -- with no sends there is nothing to do at all
; ===========================================================================
fs_bypass:
        rts
