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
;   $20 fA (per block, post-modulation)   $21 damp          $22 CAP rotation count (PERSISTENT)
;   $23 kLP  $24 kBP  $25 kHP  $2c side gain/2 (WDTH)   $26/$27 CAP lpBase/hpBase (PERSISTENT chases)
;   $28 CAP 1/nl  $29 CAP trim/2  $2a/$2b CAP o2/o1 (per sample)  $2d mode flag (0 SVF, 1 VOWL, 2 LADR, 3 CAP)
;   CAP states: hp A..F / lp A..F at $00..$0b (L), $0c..$17 (R) -- VOWL's and LADR's slots, one mode per block
;   ($1c/$1f/$23/$24 are CAP's per-sample amounts; the SVF's own uses of them never run in the same block)
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
; RATE (slot 10 KNOB of r6+$e): lfo inc = RATE^2 * $7000 + $100 per block
; (~0.08..9 Hz); fall = $7fe000 - RATE * $1e00 (~370 ms .. ~3 ms release)
        move    x:(r6+$e),a             ; a knob word: bit 23 clear, a2 = 0
        and     #>$7f0000,a
        move    a1,x0                   ; (no clean reload: the input was positive)
        move    a1,y1
        move    a1,x1                   ; RATE, kept for the fall below
        mpy     x0,y1,a
        move    a,x0
        move    #>$7000,y1
        mpy     x0,y1,a
        add     #>$100,a
        move    a,x:(r7+$47)            ; lfo inc
        move    x1,x0                   ; RATE again (decoded once, above)
        move    #$0f,y1
        mpy     x0,y1,a                 ; RATE * $1e00 in Q23
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

; ---- ENV (slot 2) and LFO (slot 3): two bipolar depths onto the cutoff ------
; (14 Sep 2026, Spectrum v2: the SRC select and the one DPTH knob became two
; page-1 knobs, 64 = none, so the touch-sensitive filter and the moving one
; are both under the hand.) FREQm = FREQ + (ENV-64)/64 * env + (LFO-64)/64 * lfo.
        move    x:(r6+$2),a             ; ENV, a knob word (bit 23 clear, a2 = 0)
        and     #>$7f0000,a
        move    #$40,x0
        sub     x0,a
        asl     #$1,a,a                 ; (ENV-64)/64, -1 .. +1
        move    a,x0
        move    x:(r7+$32),y1           ; env (>= 0)
        mpy     x0,y1,a
        move    a,x1                    ; the envelope's term
        move    x:(r6+$3),a             ; LFO
        and     #>$7f0000,a
        move    #$40,x0
        sub     x0,a
        asl     #$1,a,a
        move    a,x0
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
        move    #$10,y1                 ; 1/8
        move    y1,a                    ; a clean load: a0 = 0 for the divide
        andi    #$fe,ccr                ; carry clear
        rep     #$18
        div     x0,a                    ; 24 quotient bits land in a0
        move    a0,x0
        move    x0,x:(r7+$33)           ; d

; ---- MODE (slot 7 select of r6+$c): tap coefficients; VOWL runs the bank ---
        clr     a
        move    a,x:(r7+$2d)            ; the SVF alternative unless VOWL says so
        move    a,x:(r7+$23)
        move    a,x:(r7+$24)
        move    a,x:(r7+$25)
        move    #>$7fffff,x0
        move    x:(r6+$c),a             ; the select field where it sits (as SRC)
        and     #>$ff00,a
        cmp     #>$100,a
        beq     fs_mbp
        cmp     #>$200,a
        beq     fs_mhp
        cmp     #>$300,a
        beq     fs_mcap
        cmp     #>$400,a
        beq     fs_mvowl
        cmp     #>$500,a
        beq     fs_mladr
        move    x0,x:(r7+$23)           ; LP, and anything unexpected
        bra     fs_mdone
fs_mbp:
        move    x0,x:(r7+$24)
        bra     fs_mdone
fs_mhp:
        move    x0,x:(r7+$25)
        bra     fs_mdone
fs_mcap:
; ---- CAP (14 Sep 2026): Airwindows Capacitor2 (Chris Johnson, MIT), the
; isolator with a dielectric: a lowpass and a highpass (LOW = FREQ, HIGH =
; RES here, the knobs renamed by the mode) whose one-pole amounts are the
; knob squared, chased 1/16 per block, and per sample scaled by the signal
; itself -- |1 - x/nl|, nl = 1 + 6 (1 - NLIN/128) -- six poles per channel
; rotated three-at-a-time (modules/spectrum/capacitor2_ref.py). Per block:
; $26 lpBase, $27 hpBase (persistent chases), $28 1/nl, $29 trim/2 =
; 0.75/cbrt(nl) fitted in NLIN.
        move    #>$3,x0
        move    x0,x:(r7+$2d)           ; the loop runs the capacitor
        move    x:(r6+$0),x0
        move    x:(r6+$0),y1
        mpy     x0,y1,a                 ; (LOW/128)^2
        move    x:(r7+$26),x0
        sub     x0,a
        asr     #$4,a,a
        add     x0,a
        move    a,x:(r7+$26)            ; lpBase += (target - lpBase)/16
        move    x:(r6+$1),x0
        move    x:(r6+$1),y1
        mpy     x0,y1,a                 ; (HIGH/128)^2
        move    x:(r7+$27),x0
        sub     x0,a
        asr     #$4,a,a
        add     x0,a
        move    a,x:(r7+$27)            ; hpBase
        move    x:(r6+$5),x0            ; C = NLIN/128
        move    #$60,y1                 ; 6/8
        mpy     x0,y1,a
        neg     a
        add     #>$700000,a             ; nl/8 = 7/8 - 6C/8, 1/8 .. 7/8
        move    a,x0
        move    #$10,a                  ; 1/8 (a clean load: a0 = 0)
        andi    #$fe,ccr
        rep     #$18
        div     x0,a
        move    a0,x0
        move    x0,x:(r7+$28)           ; 1/nl, 1/7 .. 1
        move    x:(r6+$5),x0
        move    x:(r6+$5),y1
        mpy     x0,y1,a                 ; C^2
        move    a,x0
        move    #>$326e98,y1            ; 0.394
        mpy     x0,y1,a
        move    x:(r6+$5),x0
        move    #>$fb6db7,y1            ; -0.036
        mac     x0,y1,a
        add     #>$322d0e,a             ; + 0.392: trim/2 = 0.75/cbrt(nl), fitted
        move    a,x:(r7+$29)
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
        move    #$20,a                  ; num = 1/4 (a2 = a0 = 0): d/2 = (1/4)/den, <= 1/2
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
; ---- WDTH (slot 4): stereo width of the output, Character's mid/side ------
; drawn -64..+63; the knob word IS WDTH/128 = the side gain HALVED (64 -> 0.5,
; doubled back in the guard bits per sample: 0 = mono, 127 = double sides).
        move    x:(r6+$4),a
        and     #>$7f0000,a
        move    a,x:(r7+$2c)            ; ($25 is the SVF's HP tap -- 14 Sep 2026's first build put this there and every LP leaked half its HP)

; ---- BYPASS: the defaults are a bit-exact passthrough ---------------------
; FREQ 127, RES 0, ENV 64, LFO 64, WDTH 64, MODE LP (NLIN is CAP's alone).
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
        cmp     x0,a
        bne     fs_live
        move    x:(r6+$4),a
        cmp     x0,a
        bne     fs_live
        move    x:(r6+$c),a             ; the MODE select (slot 6's knob field is
        and     #>$ff00,a               ; blank since DRV went, 13 Sep 2026)
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
        move    x:(r7+$2e),a            ; g = g2run (FM went with filter B, 14 Sep 2026)
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
        move    x:(r7+$1b),a            ; wetA is the output (filter B and the mix went 14 Sep 2026)
        move    a,x:(r0)                ; out L (limited)
; ===================== channel R =====================
        move    x:(r0+n0),x0
        move    x0,x:(r7+$1d)           ; park x
        move    x:(r7+$2e),a            ; g = g2run
        move    a,x:(r7+$1c)
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
        move    x:(r7+$1b),a            ; wetA is the output (filter B and the mix went 14 Sep 2026)
        move    a,x:(r0+n0)                ; out R (limited)
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
        move    #$40,y1                 ; the formant's gain, halved
        mpy     x0,y1,a
        move    a,y0                    ; the sum so far (halved), kept in y0:
                                        ; free on this path and in fs_bmix, and
                                        ; |sum| <= 0.5 + 0.25 + 0.15 < 1, so the
                                        ; limiting move never limits (14 Sep 2026)
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
        move    #$20,y1                 ; the formant's gain, halved
        mpy     x0,y1,a
        add     y0,a
        move    a,y0                    ; the sum so far (halved)
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
        mpy     x0,y1,a
        add     y0,a
        move    a,y0                    ; the halved sum (never limits, above)
; wetA = 2 * the halved sum (= y0 + 0.5*y1 + 0.3*y2), limited -- as sum + sum,
; NOT an asl: a0 still holds the last product's low bits and a shift would
; carry its top bit into a1; the add leaves a2:a1 exactly as the shift of the
; reloaded sum did
        add     y0,a
        move    a,x:(r7+$1b)            ; wetA
        move    x:(r7+$1b),a            ; wetA is the output (filter B and the mix went 14 Sep 2026)
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
        move    #$40,y1                 ; the formant's gain, halved
        mpy     x0,y1,a
        move    a,y0                    ; the sum so far (halved), kept in y0:
                                        ; free on this path and in fs_bmix, and
                                        ; |sum| <= 0.5 + 0.25 + 0.15 < 1, so the
                                        ; limiting move never limits (14 Sep 2026)
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
        move    #$20,y1                 ; the formant's gain, halved
        mpy     x0,y1,a
        add     y0,a
        move    a,y0                    ; the sum so far (halved)
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
        mpy     x0,y1,a
        add     y0,a
        move    a,y0                    ; the halved sum (never limits, above)
; wetA = 2 * the halved sum (= y0 + 0.5*y1 + 0.3*y2), limited -- as sum + sum,
; NOT an asl: a0 still holds the last product's low bits and a shift would
; carry its top bit into a1; the add leaves a2:a1 exactly as the shift of the
; reloaded sum did
        add     y0,a
        move    a,x:(r7+$1b)            ; wetA
        move    x:(r7+$1b),a            ; wetA is the output (filter B and the mix went 14 Sep 2026)
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
        move    #>$0,x0                 ; B_prev (FM went with filter B, 14 Sep 2026)
        move    r7,r3                   ; states s0..s3 at $00
        bsr     fs_lcore
        move    x:(r7+$1b),a            ; wetA is the output (filter B and the mix went 14 Sep 2026)
        move    a,x:(r0)                ; out (limited)
; ===================== channel R =====================
        move    x:(r0+n0),x0
        move    x0,x:(r7+$1d)           ; park x
        move    #>$0,x0                 ; B_prev (0)
        move    r7,r3
        move    #$8,n3
        move    (r3)+n3                 ; states s0..s3 at $08
        bsr     fs_lcore
        move    x:(r7+$1b),a            ; wetA is the output (filter B and the mix went 14 Sep 2026)
        move    a,x:(r0+n0)                ; out (limited)
        bra     fs_join                 ; (LADR fell into CAP on the first v2 build: silent)
; MODEFORK_MID -- alternative 4: CAP, Airwindows Capacitor2 (MIT; 14 Sep 2026)
fs_cap:
; the rotation: count = (count + 1) mod 6 picks which two of the five moving
; pole pairs join pole A this sample (B or C, then D, E or F); the offsets
; come from a six-word table at $40 written at init.
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
        move    x:(r3+n3),x0            ; o2 = 3, 4 or 5
        move    x0,x:(r7+$2a)
        and     #>$1,a
        add     #>$1,a                  ; o1 = 1 or 2
        move    a1,x:(r7+$2b)
; ===================== channel L =====================
        move    x:(r0),a
        move    r7,r3                   ; L states at $00 (hp A..F) / $06 (lp A..F)
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
; ---- WDTH: mid stays, side scales (Character's width, 14 Sep 2026) --------
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
                                        ; (the `#>$2,n0 / +n0 / #>$1,n0` here
                                        ; until 14 Sep 2026 dodged a `move
                                        ; #2,n0` that "stepped ONE word per
                                        ; frame" on 3 Sep -- the OLD assembler;
                                        ; today it encodes 380200, stock's own)
fs_end:
        nop
        rts

; ---------------------------------------------------------------------------
; fs_ccore -- Capacitor2 for one channel (Airwindows, MIT; 14 Sep 2026).
; In: a = x, r3 -> the channel's twelve states (hp A..F at +0..5, lp A..F at
; +6..11), x:(r7+$2a) = o2 (3/4/5), x:(r7+$2b) = o1 (1/2) this sample.
; Out: a = x through pole A, the o1 pair and the o2 pair, times trim.
; scale/2 = |1/2 - x/(2 nl)|; amt/2 = base * scale/2; each pole is
; s' = s (1 - amt) + x amt (the second mac doubles the halved amount), a
; highpass takes x - s', a lowpass takes s'. STRAIGHT-LINE. Clobbers x0,
; x1, y0, y1, b, n3; $1d = the running x, $1f/$23/$24 = this sample's amounts.
; ---------------------------------------------------------------------------
fs_ccore:
        move    a,x:(r7+$1d)            ; x (the dry drives the dielectric)
        move    a,x0
        move    x:(r7+$28),y1           ; 1/nl
        mpy     x0,y1,a                 ; x/nl
        asr     #$1,a,a
        neg     a
        add     #>$400000,a             ; 1/2 - x/(2 nl)
        abs     a
        move    a,x0                    ; scale/2, 0 .. 1
        move    x:(r7+$26),y1           ; lpBase
        mpy     x0,y1,a
        move    a,x:(r7+$1f)            ; lpAmt/2
        asl     #$1,a,a
        neg     a
        add     #>$7fffff,a
        move    a,x:(r7+$23)            ; 1 - lpAmt  (-1 .. 1)
        move    x:(r7+$27),y1           ; hpBase
        mpy     x0,y1,a
        move    a,x:(r7+$24)            ; hpAmt/2
        asl     #$1,a,a
        neg     a
        add     #>$7fffff,a
        move    a,x:(r7+$1c)            ; 1 - hpAmt
; pole A (offset 0 / 6)
        move    #>$0,n3
        move    x:(r3+n3),x0            ; hp state
        move    x:(r7+$1c),y1
        mpy     x0,y1,a
        move    x:(r7+$1d),x0
        move    x:(r7+$24),y1
        mac     x0,y1,a
        mac     x0,y1,a                 ; s' = s (1 - amt) + x amt
        move    a,x:(r3+n3)
        move    x:(r7+$1d),b
        sub     a,b                     ; x - s'
        move    b,x:(r7+$1d)
        move    #>$6,n3
        move    x:(r3+n3),x0            ; lp state
        move    x:(r7+$23),y1
        mpy     x0,y1,a
        move    x:(r7+$1d),x0
        move    x:(r7+$1f),y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r3+n3)
        move    a,x:(r7+$1d)            ; x = s'
; the o1 pair (B or C)
        move    x:(r7+$2b),n3
        move    x:(r3+n3),x0
        move    x:(r7+$1c),y1
        mpy     x0,y1,a
        move    x:(r7+$1d),x0
        move    x:(r7+$24),y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r3+n3)
        move    x:(r7+$1d),b
        sub     a,b
        move    b,x:(r7+$1d)
        move    x:(r7+$2b),a
        add     #>$6,a
        move    a1,n3
        move    x:(r3+n3),x0
        move    x:(r7+$23),y1
        mpy     x0,y1,a
        move    x:(r7+$1d),x0
        move    x:(r7+$1f),y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r3+n3)
        move    a,x:(r7+$1d)
; the o2 pair (D, E or F)
        move    x:(r7+$2a),n3
        move    x:(r3+n3),x0
        move    x:(r7+$1c),y1
        mpy     x0,y1,a
        move    x:(r7+$1d),x0
        move    x:(r7+$24),y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r3+n3)
        move    x:(r7+$1d),b
        sub     a,b
        move    b,x:(r7+$1d)
        move    x:(r7+$2a),a
        add     #>$6,a
        move    a1,n3
        move    x:(r3+n3),x0
        move    x:(r7+$23),y1
        mpy     x0,y1,a
        move    x:(r7+$1d),x0
        move    x:(r7+$1f),y1
        mac     x0,y1,a
        mac     x0,y1,a
        move    a,x:(r3+n3)
        move    a,x0                    ; x = s'
        move    x:(r7+$29),y1           ; trim/2
        mpy     x0,y1,a
        asl     #$1,a,a                 ; out = x trim
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
        move    #$7f,x0
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
        move    #$3,n3
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
