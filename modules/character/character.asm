; ---------------------------------------------------------------------------
; CHARACTER -- crush, fold, ring, saturate, compress, width, sends.
;
; Insert contract (modules/ripple/ripple_svf.asm): frames in place at
; x:(r0)/x:(r0+n0), knobs from r6, state in this instance's r7 block. PLUS
; the bus-client contract from modules/send/send_client.asm, exactly as
; modules/spectrum/ carries it: the PROCESSED mono goes into both
; accumulators, registration is gated on each send knob, and the station
; NEVER HOUSEKEEPS (an FX1 instance runs before its track's FX2 one, so an
; electing station would double-flip the rotation -- see spectrum's
; header for the full argument).
;
; ---- the chain, fixed order ----------------------------------------------
;   x    += RET * wet                                    RET (T8 only)
;   held  = SRR ? (hold each sample 2/4/8) : x          SRR
;   q     = quantise(held, bits)                        CRSH
;   f     = fold(q * (1 + 7*FOLD/128))                  FOLD
;   r     = f * carrier                                 RING (0 = skip)
;   s     = TAPE: TapeHead(r; DRV, TONE) | TUBE/FUZZ: curve(r*drive)   DRV, SAT
;   c     = s * gain(env)                                COMP, CMOD
;   w     = width(c)                                     WDTH
;   out   = x + MIX*(w - x)                              MIX
; Distortion BEFORE dynamics: a compressor after the dirt is a tool, before
; it is a fader for the dirt.
;
; ---- the compressor (13 Sep 2026, JClones AC1, MIT) -----------------------
; AC1's console channel law for both flavours: |key| smoothed by attack /
; release, Lv = K * level_s, gr = (Lv^2/2 - 1)^2 + a*Lv clamped at 1 -- a
; dip around Lv = 1 whose depth is a = 0.75 - 0.675*COMP/128 -- and a
; makeup 1/(1 - 0.3375*COMP/128). GLUE: 0.5 / 500 ms, K = 3. COMP: 0.5 /
; 50 ms, K = 4. COMP 0 skips the stage, bit-exact. (LMC1's bus compressor
; was built and did not fit: +125 words.)
; ⚠️ THE DETECTOR READS x:(r7+$32), the KEY. Today the station writes its own
; input there; the ->KEY bus send on the backlog writes another track's, and
; nothing else changes.
;
; ---- r7 slots -------------------------------------------------------------
;   $14 $65..$69   bus bookkeeping, SEND's layout ($69 = this block's offset)
;   $15/$16 L y1/y2, $17/$18 R y1/y2: TapeHead's SVF states (PERSISTENT, /4)
;   $29 sat mode (0 TAPE = TapeHead, 1 TUBE = DaTube, 2 INFL = OInflator)  $30 k2  $31 k3mag  $48 d/8 (per block)
;   per block:
;   $20 m (MIX)   $21 fold gain/64  $22 (free, was the tanh drive)  $23 crush mask
;   $24 carrier step  $25 srr mask  $26 comp amount    $27 makeup/4
;   $28 the dip's a   $29 sat mode   $2b width side gain
;   $2c width mid gain  $2d attack coeff   $2e release coeff
;   $30 ->DEL level     $31 ->VRB level
;   $3e RET return level   ($3f, the retired DLY return level, went 14 Sep 2026:
;   it was written 0 every block and multiplied into every return sample)
;   $40 FX2-slot flag (set at init: 1 = this instance is on FX2, dry; per block)
;   $41/$42 DC block L x1/y1, $43/$44 R x1/y1 (TUBE; PERSISTENT, zeroed at init; long-form slots)
;   $37 d/2  $38 d  $4c (0.5+d)/2  $39 comp/4 (TUBE, per block)   $3a e/2  $3b 1-e (INFL, per block)
;   $46 DC block k (1 or 0), $47 R (0.999 or 0): on in TUBE only (per block)
;   $49 chtube's u/2 park (per sample)
;   $4d DRV==0: skip the saturator (per block)
;   $3c/$3d reverb / delay liveness grace (BUS mode, per block)
;   per sample / persistent (ALL BELOW $40 -- an r7 displacement past 63
;   assembles to the two-word long form, which cost the Spectrum station 30
;   words before it was found. ⚠️ Until 14 Sep 2026 dsp_asm emitted the
;   two-word form for EVERY displacement, sub-$40 included -- the one-word
;   form is the assembler's since then, and only since then):
;   $19 held L (PERSISTENT)      $1a held R (PERSISTENT)
;   $1b srr counter (PERSISTENT) $1c carrier phase (PERSISTENT)
;   $1d (free)  $1e level_s (PERSISTENT)  $2a (free)
;   $1f gr (per sample)  $45 (free)  $22 K/4 (per block)
;   $32 key    $33 dry L park   $34 dry R park
;   $35 scratch (wet L)          $36 scratch (wet R)
;   r4 / r5: the REVERB / DELAY wet read pointers (BUS mode), linear, per
;   block from the rotation -- two buffers back, like every bus read.
;
; ---- the return, by position (13 Sep 2026; was "BUS mode", 3 Sep) -------
; Slot 4, RET, is the return level: on the master (dispatch position 3 on
; payload A, track 8) each sample the last live stage's wet -- the reverb's
; if it runs, else the delay's -- is added at that level BEFORE the chain,
; and each block the station stamps the bus's liveness word (y:$9d8 /
; y:$9d9) while RET is up, which tells that engine to stop printing its wet
; on its own host. Anywhere else RET is inert (a return only exists where
; the mix is). There is no mode switch any more: SAT is TAPE / TUBE / FUZZ
; on every track, T8 included, and no knob changes meaning by mode.
;
; CYCLES_FORWARD_BRANCHES -- the SRR hold and the RING gate are the only
; branches left in the sample loop, both forward and both skipping work, so
; the word span is the worst-case cycle count (tools/build/cycle_count.py). The
; saturation character and the compressor mode are per-block COEFFICIENTS
; for exactly this reason: a dispatch inside the loop cannot be priced.
;
; Every mpy is `mpy x0,y1` (the audited-signed encoding) except the three
; in the callees whose second operand is a non-negative coefficient, each
; commented at its site. Every Tcc reads the ONE compare above it with nothing but moves
; between (the flag-clobber trap).
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
        move    b,x:(r7+$40)          ; 1 = dry pass
        clr     a
        move    a,x:(r7+$41)            ; the DC blocker's state, both channels
        move    a,x:(r7+$42)
        move    a,x:(r7+$43)
        move    a,x:(r7+$44)
        move    a,x:(r7+$15)            ; TapeHead's SVF states, both channels
        move    a,x:(r7+$16)
        move    a,x:(r7+$17)
        move    a,x:(r7+$18)
        move    a,x:(r7+$1e)            ; the compressor's state: AC1 level_s
        move    #>$7fffff,x0
        move    x0,x:(r7+$1f)           ; gr = unity
        rts

proc:
        move    x:(r7+$40),a           ; an FX2 slot: dry, nothing written
        tst     a
        bne     ch_end
; ===========================================================================
; BUS: split-aware frame offset, verbatim from modules/send/send_client.asm
; ===========================================================================
        move    a,x:(r7+$14)
        clr     a
        move    a,x:(r7+$67)
        move    x:(r7+$14),a
        tst     a
        bne     ch_a1
        move    #>$1,a
        move    a,x:(r7+$65)
        move    n7,a
        and     #>$f,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$66)
        bra     ch_offok
ch_a1:
        move    x:(r7+$65),a
        and     #>$ff,a
        move    a1,x0
        move    x0,a
        move    #>$1,x0
        cmp     x0,a
        bne     ch_offok
        clr     a
        move    a,x:(r7+$65)
        move    x:(r7+$66),a
        and     #>$f,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$67)
ch_offok:
; ---- resolve this block's rotation (per payload) -> r7+$69 -----------------
; ROTLATCH
; (the registration went with the sends, 12 Sep 2026; the rotation latch
; above stays: the returns read the engines' outputs by it)

; ===========================================================================
; PER-BLOCK KNOB DECODE
; ===========================================================================
; MIX: page-2 slot 6, the KNOB field of r6+$c (the word SAT's select shares)
        move    x:(r6+$c),a             ; a knob word: bit 23 clear, a2 = 0
        and     #>$7f0000,a
        move    a1,x:(r7+$20)           ; m (a1 straight to memory)
; fold gain/64 = (1 + 47*FOLD/128)/64 -- 1x .. 48x into the fold, pre-divided
; by 64 so the fold's (v+1)/2 arithmetic keeps its guard bits (the loop
; shifts by 5). WarpFold's 1x..8x law (until 12 Sep 2026) was sized for the
; old harness's 0.5 FS input; the unit hands the chain ~0.13 FS at AMP VOL
; 64 (the mixer model, COLDFIRE_PORT.md O14), where 8x reached the FIRST
; fold only at FOLD 127 -- +15 dB of gain and 12 % THD, a volume knob. The
; 1x..32x law that followed left the first quarter of the dial dead on a
; pad (nothing folds until gain * peak crosses 1: ~8x at that level, FOLD
; 28) while 80 -> 127 still grew (ear, 12 Sep 2026); doubled to 64x, 127
; was "insane, maybe too much": 48x.
        move    x:(r6+$1),x0            ; the knob word IS FOLD/128 in Q23
        move    #$5e,y1                 ; 47/64 (short immediate: bits 23-16)
        mpy     x0,y1,a                 ; (47/64)*(FOLD/128)
        add     #>$020000,a             ; + 1/64 -> gain/64, 0.016 .. 0.75
        move    a,x:(r7+$21)            ; gq
; DRV 0 = NO saturation stage at all (13 Sep 2026): every mode's curve is
; unity only for small signals, and with the return entering BEFORE the
; chain the master's whole mix would pass through it. A per-block flag ($4d) skips the stage per sample -- a forward
; skip, the class CYCLES_FORWARD_BRANCHES admits -- so DRV 0 is bit-exact in
; every mode on every track. (The DC blocker / low-pass state is NOT cleared
; while skipped -- 9 words the BURN build on payload A did not have; a later
; DRV resumes from stale filter history, one small step at most.)
        move    x:(r6+$0),a             ; DRV
        clr     b                       ; b = 0 BEFORE the tst (the flag trap)
        move    #>$1,x0
        tst     a
        teq     x0,b                    ; DRV == 0 -> skip flag 1
        move    b,x:(r7+$4d)
; CRSH -> a bit MASK, built ONCE PER BLOCK (the per-sample cost is then one
; AND). The knob picks how many low bits are cleared, 0..21; the mask is
; $ffffff shifted left that many times, and the shift runs in a `do` loop
; here rather than a `rep` per sample.
; bits = 21 * knob / 128. The knob word IS knob/128 in Q23, so the product
; with 21/128 is 21*knob/2^14 as a fraction; one asr #16 of the accumulator
; leaves the plain integer.
        move    x:(r6+$2),x0
        move    #$15,y1                 ; 21/128 (short immediate: bits 23-16)
        mpy     x0,y1,a
        asr     #$10,a,a                ; -> the integer, 0..20
        move    a1,x0
        move    x0,a
        move    #>21,x0
        cmp     x0,a
        tgt     x0,a                    ; belt and braces: never past 21
        move    a,y0                    ; bits to drop, 0..21 -- the do count
        tst     a                       ; (tst takes an ACCUMULATOR, never a
        move    #>$ffffff,a             ; register; a move does not disturb it)
        beq     ch_mskz                 ; knob 0: the all-ones mask, unshifted
        do      y0,>ch_mskl
        asl     #$1,a,a
        move    a1,x0                   ; asl leaves A2 stale every trip
        move    x0,a
ch_mskl:
        nop
ch_mskz:
        move    a,x:(r7+$23)            ; the mask: AND clears the low bits
; RING: carrier step, WarpFold's squared taper; 0 = OFF (a step of 0 leaves
; the phase still, and the per-sample gate below skips the multiply)
        move    x:(r6+$d),a             ; a knob word: bit 23 clear, a2 = 0
        and     #>$7f0000,a
        move    a1,x0                   ; (no clean reload: the input was positive)
        move    a1,y1
        mpy     x0,y1,a                 ; RING^2
        move    a,x0
        move    #>$116000,y1            ; 2.95 kHz at full knob: step = 2f/fs
                                        ; over (127/128)^2. ($5a0000 put 127
                                        ; at 15 kHz and 20 at 379 Hz, measured
                                        ; on the sidebands 12 Sep 2026 -- the
                                        ; comment said 2.95 k, the value did not)
        mpy     x0,y1,a
        move    a,x:(r7+$24)            ; carrier step
; SRR (slot 11 select of r6+$e): hold mask 0 / 1 / 3 / 7
        move    x:(r6+$e),a
        and     #>$ff00,a
        move    a1,x0
        move    x0,a
        asl     #$8,a,a
        move    #>$10000,x0
        cmp     x0,a
        beq     ch_srr2
        move    #>$20000,x0
        cmp     x0,a
        beq     ch_srr4
        move    #>$030000,x0            ; 3<<16 (zero-padded: not the base
        cmp     x0,a                    ; literal the build rewrites)
        beq     ch_srr8
        clr     a                       ; OFF, and anything unexpected
        bra     ch_srrz
ch_srr2:
        move    #>$1,a
        bra     ch_srrz
ch_srr4:
        move    #>$3,a
        bra     ch_srrz
ch_srr8:
        move    #>$7,a
ch_srrz:
        move    a,x:(r7+$25)            ; srr mask
; COMP amount, straight from the knob
        move    x:(r6+$3),x0
        move    x0,x:(r7+$26)
; CMOD (slot 9 select of r6+$d): both flavours are AC1's console channel
; law (JClones, MIT; 13 Sep 2026 -- docs/effects/PORTS.md), differing in
; their constants: GLUE = attack 0.5 ms / release 500 ms, the detector at
; 3x (Lv/2 = 1.5*level_s); COMP = the same dip driven harder, 4x, with a
; 50 ms release. (LMC1's bus compressor was built and measured too big:
; +125 words with its two tables; the draft is kept beside the session.)
; a = 0.75 - 0.675*COMP/128 (the JSFX's Comp 1..10 on the knob); makeup =
; 1/(1 - 0.3375*COMP/128), HALF the JSFX's auto-gain in dB terms (that one
; restores unity at the dip's bottom and lifts a mix that mostly sits below
; the dip: +2.1 dB at COMP 40; this is +1.0 dB, today's GLUE on the unit).
        move    x:(r6+$d),a
        and     #>$ff00,a
        move    a1,x0
        move    x0,a
        asl     #$8,a,a
        move    #>$10000,x0
        cmp     x0,a
        beq     ch_cglue
        move    #>$7fffff,x0            ; COMP: K/4 = 1.0 (4x), release 50 ms
        move    x0,x:(r7+$22)
        move    #>$000bd0,x0
        move    x0,x:(r7+$2e)
        bra     ch_cset
ch_cglue:
        move    #$60,x0                 ; GLUE: K/4 = 0.75 (3x), release 500 ms
        move    x0,x:(r7+$22)
        move    #>$00017c,x0
        move    x0,x:(r7+$2e)
ch_cset:
        move    #>$05ce1b,x0            ; attack 0.5 ms: 1/(fs*t), both
        move    x0,x:(r7+$2d)
        move    x:(r7+$26),x0           ; COMP/128
        move    #>$566666,y1            ; 0.675
        mpy     x0,y1,a
        neg     a
        add     #>$600000,a             ; a = 0.75 - 0.675*COMP/128
        move    a,x:(r7+$28)
        move    #>$2b3333,y1            ; 0.3375
        mpy     x0,y1,a
        neg     a
        add     #>$7fffff,a             ; den = 1 - 0.3375*COMP/128 (0.66..1)
        move    a,x0
        move    #$20,a                  ; num = 0.25 (a1), a2 = a0 = 0 (short: bits 23-16)
        andi    #$fe,ccr
        rep     #$18
        div     x0,a
        move    a0,x0
        move    x0,x:(r7+$27)           ; m/4 = 0.25/den: makeup/4
ch_cdone:
; SAT character (slot 7 select of r6+$c) -> a MODE FLAG and per-mode words,
; so the sample loop's SAT stage is a MODEFORK: TAPE (0) = TapeHead, TUBE (1)
; = DaTube, INFL (2) = OInflator (all JClones, MIT; 13 Sep 2026). The tanh
; curve, its P table, FUZZ and the drive-keyed low-pass are gone. A stored 3
; (the old BUS) lands on TAPE. Per-mode words, all from DRV = d (0..0.992):
;   TUBE  $37 = d/2 (the positive half's scale)  $38 = d (the negative half's)
;         ($4c = (0.5 + d)/2 input gain and $39 = comp/2 below, every mode)
;         $46/$47 = the DC blocker on (k 1, R 0.999)
;   INFL  $3a = e/2 with e = d            $3b = 1 - e
        clr     a
        move    a,x:(r7+$46)            ; the DC blocker off (k = R = 0) unless TUBE
        move    a,x:(r7+$47)
        move    a,x:(r7+$3e)            ; return level: 0 until RET is read below
        move    a,x:(r7+$29)            ; sat mode: 0 = TAPE
        move    x:(r6+$c),a
        and     #>$ff00,a
        move    a1,x0
        move    x0,a
        asl     #$8,a,a
        move    #>$10000,x0
        cmp     x0,a
        beq     ch_stube
        move    #>$20000,x0
        cmp     x0,a
        beq     ch_sinfd
        bra     ch_sdone                ; TAPE (a stored 3, the old BUS, too)
ch_stube:
        move    #>$1,x0
        move    x0,x:(r7+$29)           ; sat mode 1: TUBE
        move    x:(r6+$0),a             ; d = DRV/128
        move    a,x:(r7+$38)            ; the negative half: d
        asr     #$1,a,a
        move    a,x:(r7+$37)            ; the positive half: d/2
        move    #>$7fffff,x0            ; the DC blocker on: TUBE's asymmetry
        move    x0,x:(r7+$46)           ; leaves DC (JClones' own 3 Hz remover;
        move    #>$7fdf3b,x0            ; ours is R = 0.999, ~7 Hz, as it was)
        move    x0,x:(r7+$47)
        bra     ch_sdone
ch_sinfd:
        move    #>$2,x0
        move    x0,x:(r7+$29)           ; sat mode 2: INFL
        move    x:(r6+$0),a             ; e = DRV/128
        move    a,x0
        asr     #$1,a,a
        move    a,x:(r7+$3a)            ; e/2
        move    #>$7fffff,a
        sub     x0,a
        move    a,x:(r7+$3b)            ; 1 - e (DRV 0 never gets here: the skip)
ch_sdone:
; ---- RET: the return level, BY POSITION (13 Sep 2026) ---------------------
; Slot 4 is the return level. It does something on ONE track: the return is
; pinned to dispatch position 3 on payload A (track 8, the master) exactly
; as it was when BUS was a mode of SAT -- only the mode is gone. Character is
; one insert with every mode on every track, T8 included; the master gets a
; RET knob and the bus wet enters at the FRONT of the chain (the sample
; loop), so glue, saturation, width and tone treat dry plus wet together.
; Safe by construction: the stations have had no sends since 7 Sep 2026 and
; T8 cannot send, so a return before the chain can never re-enter a bus.
        move    x:(r6+$4),x0
        move    x0,x:(r7+$3e)           ; RET level (slot 4)
; ... on PAYLOAD A ONLY: the mirror position on core 1 is track 4. An insert
; carries no per-payload literal (an FX1 module may own no buffers, so the
; build refuses it a base), so the core is read off the DISPATCH TABLE: in
; the specialized image BusVerb (id 0x07) is real on payload A and ALIASED
; TO SEND (id 0x09) on payload B -- X:$215+7 == X:$215+9 there. Under the
; DEV hatch everything is payload A and the test allows. Consequence: a
; remix WITHOUT BusVerb has no return anywhere (its id aliases on both
; cores); the rig always carries it on T5.
        move    x:>$21c,a               ; INIT_TABLE[REVERB SERVER]
        move    x:>$21e,x0              ; INIT_TABLE[SEND]
        cmp     x0,a
        beq     ch_nopos                ; the alias: payload B, never the return
        move    r7,a
        and     #>$ff00,a
; ⚠️ r7 is NOT 0x6100 + 0x100 * (2*pos + fx-1). The stock dispatcher bumps
; its r7 counter THREE times per track (FX1 at P:0x4ae, FX2 at P:0x4e4 and
; an unconditional third at P:0x51e after FX2), so a track's FX1 is at
; 0x6100 + 0x300*pos and its FX2 at 0x6200 + 0x300*pos -- measured 8 Sep
; 2026 on BOTH payloads with the firmware driving the DSP (the ColdFire port,
; COLDFIRE_PORT.md O11): position 3 is $6a00/$6b00. The old $6700/$6800 was
; the harness's two-per-track model (dsp_host's r7probe comment), matched
; ONLY in dsp_host -- which is why verify_onebus was green while the unit
; never returned (FAILURE_MODES "the one-aux return never reaches T8":
; the station ran with r7 = $6a00, took ch_nopos, cleared RET, stamped
; nothing, and both hosts kept printing -- reproduced under the port).
; Only $6a00 (position 3's FX1) can get here: position 3's FX2 is $6b00,
; and an FX2 instance's allocator base is 0x4000/0x8000/0x30000/0x34000
; (the X:0x255 table, DSP.md s10), so its $40 flag returns proc at its
; first instruction. The $6b00 compare that sat here went 14 Sep 2026.
        move    #>$6a00,x0
        cmp     x0,a
        beq     ch_pos3
ch_nopos:
        clr     a
        move    a,x:(r7+$3e)            ; not track 8: no return
ch_pos3:
; TUBE's post gain: comp(d) = 1 / ((0.5 + d)(1 + 1.727 d)), the inverse of
; DaTube's average small-signal gain (its positive half's slope is 1 + 1.151 d,
; the negative's 1 + 2.303 d, times the (0.5 + d) input gain), so the drive
; densifies rather than turns up: 2.0 at d = 0, 0.244 at d = 1. Computed with
; the block's real division, no table: comp/4 = (1/32) / D8 with D8 = D/8 =
; ((0.5 + d)/2)((1 + 1.727 d)/4), D in [0.5, 4.1], so D8 in [1/16, 0.52] and
; the quotient in [0.12, 1.0]. $39 = comp/2; chtube's asl #3 makes 2*y*comp,
; the JSFX's own 2x output gain (its -6 dB default slider is not modelled).
        move    x:(r6+$0),a             ; d = DRV/128
        move    a,x1                    ; (x1 = DRV/128 for TapeHead's words below)
        move    a,x0
        move    #>$37445f,y1            ; 0.43175 = 1.727/4
        mpy     x0,y1,a
        add     #>$200000,a             ; (1 + 1.727 d)/4
        move    a,x0
        move    x1,a
        asr     #$1,a,a
        add     #>$200000,a             ; (0.5 + d)/2
        move    a,x:(r7+$4c)            ; TUBE's input gain, halved
        move    a,y1
        mpy     x0,y1,a                 ; D8
        move    a,x0                    ; den
        move    #$08,y1                 ; 1/16
        move    y1,a                    ; a clean load: a0 = 0 for the divide
        andi    #$fe,ccr                ; carry clear
        rep     #$18
        div     x0,a                    ; 24 quotient bits land in a0
        move    a0,x0
        move    x0,x:(r7+$39)           ; comp/2
; the P table: TUBE_UP (17 pairs, DaTube's curve) then TAPE_D8 (9 words).
        move    #>$fab1e0,r1            ; TUBE_UP -- rewritten by build_bus.py
        move    #>$ffffff,m1
        move    r1,r2
        move    (r2)+                   ; r2 = its slopes
; ---- TapeHead's per-block words (TAPE only reads them; computed always) --
; d8 = d/8 from TAPE_D8 (the 17 words after TUBE_UP's 34), interpolated over
; DRV/128 (idx = DRV >> 19, frac = the 19 bits under it); k2 linear in
; TONE/128 (2.1 -> 5 kHz);
; k3mag = 1.4*k2 = (0.7*k2)*2. The table sits in the manifest after DaTube's
; curve, so the one P-table literal above still finds everything.
        move    r1,r3
        move    #$22,n3                 ; 34 (short immediate: an integer)
        move    #>$ffffff,m3
        move    x1,a                    ; DRV/128
        asr     #$13,a,a
        move    (r3)+n3                 ; r3 = TAPE_D8
        move    a1,n3
        move    x1,a
        and     #>$7ffff,a
        asl     #$4,a,a
        move    a,x0                    ; frac
        move    (r3)+n3
        move    p:(r3)+,y0              ; D8[idx]
        move    p:(r3),b                ; D8[idx+1]
        move    y0,a
        sub     a,b                     ; diff (> 0: the table rises)
        move    b,y1
        mpy     x0,y1,a
        add     y0,a
        move    a,x:(r7+$48)            ; d8 = d/8, 0.1 .. 0.98
        move    x:(r6+$5),a             ; TONE/128
        and     #>$7f0000,a
        move    a1,x0
        move    #>$331d23,y1            ; k2 = 0.2981 + 0.3993*TONE/128 (the sine's
        mpy     x0,y1,a                 ; curve is 0.5 % from linear over 2.1..5 kHz)
        add     #>$2627a2,a
        move    a,x:(r7+$30)            ; k2
        move    a,x0
        move    #>$59999a,y1            ; 0.7: k3mag = 1.4 * k2, halved
        mpy     x0,y1,a
        asl     #$1,a,a
        move    a,x:(r7+$31)            ; k3mag (< 0.98)
; WDTH -> mid and side gains. 64 = (1, 1); 0 = (1, 0) mono; 127 = (1, ~2).
; side gain = WDTH/64, mid stays 1 -- widening only touches the difference,
; so a mono source is untouched at every setting.
        move    x:(r6+$e),a             ; a knob word: bit 23 clear, a2 = 0
        and     #>$7f0000,a
; ⚠️ STORED HALVED. A y1 operand is a FRACTION, and a side gain of WDTH/64
; tops out near 2.0, which would wrap the word. The knob's own value IS
; WDTH/128, so it is stored as-is and the product is doubled back in the
; accumulator's guard bits. 64 -> 0.5 -> x2 = exactly 1.0, i.e. untouched.
        move    a1,x:(r7+$2b)           ; side gain / 2 (a1 straight to memory)
; ---- the return read pointers, and the liveness stamps -------------------
; Two buffers back, like every bus read (an idle block each side of the
; reader on both cores); x2 throughout because the wet buffers are stereo,
; 32 words each. The delay's page is the reverb's + $80 (spelled as base +
; offset, so the XBUS relocation of `$9xx` literals catches the base).
        move    x:(r7+$69),a            ; this block's write offset
        add     #>$20,a
        and     #>$30,a                 ; two back, mod 4
        move    a1,x0
        move    x0,a                    ; A2-clean after the and
        add     x0,a                    ; x2
        move    x:(r7+$67),b            ; split-aware frame offset
        add     b,a
        add     b,a                     ; + frame x2
        add     #>$9da,a
        move    a,r4                    ; REVERB output [read]
        add     #>$80,a
        move    a,r5                    ; DELAY output [read]
        move    #>$ffffff,m4
        move    #>$ffffff,m5
; ---- ONLY THE RETURN READS THE STAMPS (9 Sep 2026, found under the port) --
; The engines' liveness words are clear-on-read, single reader by design. A
; BUS-mode station on any OTHER track (T4, T7 -- flash 6's claim vii only
; asked that it return nothing, and it does) was still running this block,
; stealing the stamps before T8's return read them: with such a station in
; the part the REAL return went silent from its first sample (the port,
; COLDFIRE_PORT.md O12; the local gate never tried both at once). A station
; whose RET level is 0 -- not track 8, or the knob down -- has no business
; here: skip the reads AND the RETV/RETD stamps below. (The engines then
; keep printing, which is what a return at 0 means.)
        move    x:(r7+$3e),a
        tst     a
        beq     ch_ndl                  ; no return level: touch nothing
; ---- which stage is live? (one-aux rig, 7 Sep 2026) ---------------------
; Each engine stamps its own word every block it processes (y:$9c4 reverb,
; y:$9c5 delay); this reads and clears them (single writer, single reader)
; and keeps 3 blocks of grace each in r7 $3c/$3d -- RETV's shape, for a
; stamp the other core's timing loses. Reverb live: read its output (r4).
; Delay live only: read the delay's (r4 := r5). Neither: the level is 0.
        move    x:(r7+$3c),a            ; reverb grace
        and     #>$3,a
        move    a1,x0
        move    x0,b
        move    #>$1,x0
        sub     x0,b
        move    #$0,x0
        tmi     x0,b
        move    y:>$9c4,a
        move    x0,y:>$9c4              ; clear-on-read
        move    #>$3,x0
        tst     a
        tne     x0,b
        move    b,x:(r7+$3c)
        move    x:(r7+$3d),a            ; delay grace
        and     #>$3,a
        move    a1,x0
        move    x0,b
        move    #>$1,x0
        sub     x0,b
        move    #$0,x0
        tmi     x0,b
        move    y:>$9c5,a
        move    x0,y:>$9c5              ; clear-on-read
        move    #>$3,x0
        tst     a
        tne     x0,b
        move    b,x:(r7+$3d)
        move    x:(r7+$3c),a
        tst     a
        bne     ch_rvlive               ; reverb live: r4 is right already
        move    x:(r7+$3d),a
        tst     a
        beq     ch_nolive
        move    r5,r4                   ; delay only: return the delay's output
        bra     ch_rvlive
ch_nolive:
        clr     a
        move    a,x:(r7+$3e)            ; nothing live: return nothing
ch_rvlive:
        move    x:(r7+$3e),a            ; RET up: tell BOTH hosts to go quiet
        tst     a
        beq     ch_ndl
        move    #>$1,x0
        move    x0,y:>$9d8
        move    x0,y:>$9d9
ch_ndl:
; ---- BYPASS: the defaults are a bit-exact passthrough ---------------------
; DRV 0, FOLD 0, CRSH 0, COMP 0, MIX 127, RING 0, WDTH 64, SRR OFF. Every
; part that ever chose LO-FI runs this after the flash, so the neutral block
; does nothing at all.
        move    x:(r6+$0),a             ; DRV
        tst     a
        bne     ch_live
        move    x:(r6+$1),a             ; FOLD
        tst     a
        bne     ch_live
        move    x:(r7+$23),a            ; crush MASK (not the knob: in BUS
        move    #>$ffffff,x0            ; mode the knob is RVRB and the mask
        cmp     x0,a                    ; is identity)
        bne     ch_live
        move    x:(r7+$3e),a            ; a return level up needs the loop
        tst     a
        bne     ch_live
        move    x:(r6+$3),a             ; COMP
        tst     a
        bne     ch_live
        move    x:(r7+$24),a            ; carrier step (RING)
        tst     a
        bne     ch_live
        move    x:(r7+$25),a            ; srr mask
        tst     a
        bne     ch_live
        move    x:(r7+$2b),a            ; side gain/2: 64 -> exactly 0.5
        move    #$40,x0
        cmp     x0,a
        beq     ch_bypass
ch_live:

; ===========================================================================
; THE SAMPLE LOOP
; ===========================================================================
        move    #$1,n0                  ; (short immediate, stock's own form)
        do      n7,>ch_end
; ---- the return FIRST (13 Sep 2026): the bus wet enters before the chain --
; Skipped per sample when the level is 0 -- a forward skip, the class
; CYCLES_FORWARD_BRANCHES admits. The wet in x0 goes negative, so the mpy is
; the audited-signed x0,y1 order; the level is the knob word (val/128, >= 0).
; (r5, the delay's own read pointer, is still set per block: the delay-only
; case above returns it through r4. The second tap that read y:(r5)+ at the
; retired DLY level -- a hard 0 -- went 14 Sep 2026.)
        move    x:(r7+$3e),a
        tst     a
        beq     ch_noret
        move    x:(r0),a
        move    y:(r4)+,x0              ; wet L (the last live stage's)
        move    x:(r7+$3e),y1           ; RET
        mpy     x0,y1,b
        add     b,a
        move    a,x:(r0)
        move    x:(r0+n0),a
        move    y:(r4)+,x0              ; wet R
        move    x:(r7+$3e),y1
        mpy     x0,y1,b
        add     b,a
        move    a,x:(r0+n0)
ch_noret:
; ---- park the dry, and take the key (the mono sum) ------------------------
        move    x:(r0),a
        move    a,x:(r7+$33)
        move    x:(r0+n0),x0
        move    x0,x:(r7+$34)
        add     x0,a
        asr     #$1,a,a
        move    a,x:(r7+$32)            ; key = mono in (the ->KEY hook)
; ---- SRR: hold the pair for 2/4/8 samples ---------------------------------
        move    x:(r7+$25),a            ; mask
        tst     a
        beq     ch_nosrr
        move    x:(r7+$1b),b            ; counter
        add     #>$1,b
        move    b1,x0
        move    x0,b
        move    b,x:(r7+$1b)
        and     x0,a                    ; counter & mask -- AND sets Z from A1,
        bne     ch_hold                 ; which is what the tst on a clean
                                        ; reload saw (a2 = a0 = 0 here); not a
                                        ; fresh sample: reuse the held
        move    x:(r0),x0               ; fresh: latch this pair
        move    x0,x:(r7+$19)
        move    x:(r0+n0),x0
        move    x0,x:(r7+$1a)
ch_hold:
        move    x:(r7+$19),x0           ; the held pair drives the chain
        move    x0,x:(r7+$33)
        move    x:(r7+$1a),x0
        move    x0,x:(r7+$34)
ch_nosrr:
; ---- CRSH: one AND per channel with the per-block mask -------------------
; ⚠️ AND leaves A2 STALE and a `move a,x:` would saturate (CLAUDE.md), so
; each value leaves through a1 -- straight to memory, which no limiter sees.
        move    x:(r7+$23),x0           ; mask
        move    x:(r7+$33),a
        and     x0,a
        move    a1,x:(r7+$33)
        move    x:(r7+$34),a
        and     x0,a
        move    a1,x:(r7+$34)
; ---- FOLD: WarpFold's wrap-and-reflect, both channels --------------------
        move    x:(r7+$33),x0
        move    x:(r7+$21),y1           ; gq = gain/64
        mpy     x0,y1,a                 ; v/64
        asl     #$5,a,a                 ; v/2
        move    #$40,x1                 ; 0.5 (short immediate: bits 23-16)
        add     x1,a                    ; (v+1)/2
        move    a1,x1                   ; s = wrap(...), raw A1: the fold
        move    x1,a                    ; clean re-load, A2 consistent
        abs     a
        move    #$40,b                  ; 0.5, b2 = b0 = 0
        sub     b,a                     ; |s| - 0.5
        asl     #$1,a,a                 ; fold in [-1,1)
        move    a,x:(r7+$35)            ; wet L
        move    x:(r7+$34),x0
        move    x:(r7+$21),y1
        mpy     x0,y1,a
        asl     #$5,a,a
        move    #$40,x1
        add     x1,a
        move    a1,x1
        move    x1,a
        abs     a
        move    #$40,b
        sub     b,a
        asl     #$1,a,a
        move    a,x:(r7+$36)            ; wet R
; ---- RING: one carrier, both channels ------------------------------------
        move    x:(r7+$24),a            ; step
        tst     a
        beq     ch_noring
        move    x:(r7+$1c),b            ; phase
        move    a,x0
        move    b,a
        add     x0,a
        move    a1,x0                   ; p = wrapped phase
        move    x0,x:(r7+$1c)
        move    x0,a
        abs     a
        move    #$80,y1                 ; -1.0 (short immediate: bits 23-16)
        add     y1,a                    ; |p| - 1
        neg     a                       ; t = 1 - |p|
        move    a,y1
        mpy     x0,y1,a                 ; p*t
        asl     #$2,a,a                 ; carrier = 4*p*t
        move    a,y0                    ; held for both channels
        move    x:(r7+$35),x0
        mpy     y0,x0,a                 ; wet * carrier (signed order)
        move    a,x:(r7+$35)
        move    x:(r7+$36),x0
        mpy     y0,x0,a
        move    a,x:(r7+$36)
ch_noring:
; ---- SATURATE: the character (13 Sep 2026, all JClones, MIT). TAPE is
; TapeHead, TUBE is DaTube, INFL is OInflator: one straight-line callee per
; mode per channel (a = the sample in, b = out; the caller's store is the
; hard clip). Skipped whole when DRV is 0 ($4d, per block). The three
; alternatives are a MODEFORK so the pricer charges the worst, not all.
        move    x:(r7+$4d),a
        tst     a
        bne     ch_nosat
; MODEFORK_BEGIN -- cycle_count.py: the dispatch, one flag test
        move    x:(r7+$29),a
        tst     a
        bne     ch_s12
; MODEFORK_MID -- alternative 1: TAPE = TapeHead
; r3 -> the channel's y1/y2 pair (the SVF state).
        move    #$15,n3
        move    r7,r3
        move    x:(r7+$35),a            ; L in (post fold/ring)
        move    (r3)+n3                 ; r3 = r7+$15: L y1, y2
        bsr     chtape
        move    b,x:(r7+$35)            ; LIMITING store: the hard clip
        move    #$17,n3
        move    r7,r3
        move    x:(r7+$36),a            ; R in
        move    (r3)+n3                 ; r3 = r7+$17: R y1, y2
        bsr     chtape
        move    b,x:(r7+$36)
        bra     ch_nosat
; MODEFORK_MID -- alternative 2: TUBE = DaTube (one compare more: 1 or 2)
ch_s12:
        move    #>$1,x0
        cmp     x0,a
        bne     ch_sinfl
; r3 -> the channel's DC-blocker pair (x1, y1).
        move    #$41,n3
        move    r7,r3
        move    x:(r7+$35),a            ; L in
        move    (r3)+n3                 ; r3 = r7+$41: L x1, y1
        bsr     chtube
        move    b,x:(r7+$35)            ; LIMITING store: the clip
        move    #$43,n3
        move    r7,r3
        move    x:(r7+$36),a            ; R in
        move    (r3)+n3                 ; r3 = r7+$43: R x1, y1
        bsr     chtube
        move    b,x:(r7+$36)
        bra     ch_nosat
; MODEFORK_MID -- alternative 3: INFL = OInflator (stateless)
ch_sinfl:
        move    x:(r7+$35),a            ; L in
        bsr     chinfl
        move    b,x:(r7+$35)            ; LIMITING store: the clip (|out| <= 1)
        move    x:(r7+$36),a            ; R in
        bsr     chinfl
        move    b,x:(r7+$36)
; MODEFORK_END
ch_nosat:
; ---- COMPRESS (13 Sep 2026, JClones AC1, MIT): COMP 0 skips the stage
; (bit-exact); else |key| smoothed by the flavour's attack / release, Lv =
; K * level_s, gr = (Lv^2/2 - 1)^2 + a*Lv, <= 1 by the limiting store --
; a dip around Lv = 1 -- then x *= gr * makeup on both channels. Lv is
; carried halved (Lv/2, so Lv up to 2 fits a word; the dip is over by 1.5).
        move    x:(r7+$26),a            ; COMP
        tst     a
        beq     ch_capd                 ; COMP 0: the stage is skipped
        move    x:(r7+$32),a            ; key
        abs     a
        move    a,x0                    ; level
        move    x:(r7+$1e),b            ; level_s
        move    x0,a
        sub     b,a                     ; d = level - level_s
        move    x:(r7+$2d),x1           ; attack
        move    x:(r7+$2e),b            ; release
        tst     a                       ; nothing between this and the Tcc
        tpl     x1,b                    ; rising: attack
        move    b,y1
        move    a,x0
        mpy     x0,y1,a                 ; k*d
        move    x:(r7+$1e),b
        add     b,a
        move    a,x:(r7+$1e)            ; level_s
        move    a,x0
        move    x:(r7+$22),y1           ; K/4
        mpy     x0,y1,a
        asl     #$1,a,a
        move    a,x0                    ; Lv/2 (the limiting store: Lv <= 2)
        move    x0,y1
        mpy     x0,y1,a                 ; (Lv/2)^2
        asl     #$1,a,a                 ; Lv^2/2
        add     #>$800000,a             ; t = Lv^2/2 - 1  (-1 .. 1)
        move    a,x1                    ; t (clean)
        move    x:(r7+$28),y1           ; a
        mpy     x0,y1,b                 ; a*Lv/2  (x0 = Lv/2 >= 0)
        asl     #$1,b,b                 ; a*Lv
        move    x1,x0                   ; t goes negative below the dip: the
        move    x1,y1                   ; square must be the audited x0,y1
        mpy     x0,y1,a                 ; t^2   (mpy x1,y1 encodes as mpysu)
        add     b,a                     ; gr = t^2 + a*Lv
        move    a,x:(r7+$1f)            ; gr (the limiting store: <= 1)
ch_capp:
        move    x:(r7+$1f),x0           ; gr
        move    x:(r7+$27),y1           ; makeup/4
        mpy     x0,y1,a
        move    a,y1                    ; gr*makeup/4
        move    x:(r7+$35),x0
        mpy     x0,y1,a
        asl     #$2,a,a
        move    a,x:(r7+$35)
        move    x:(r7+$36),x0
        mpy     x0,y1,a
        asl     #$2,a,a
        move    a,x:(r7+$36)
ch_capd:
; ---- WIDTH: mid stays, side scales ---------------------------------------
        move    x:(r7+$35),a            ; L
        move    x:(r7+$36),x0           ; R
        add     x0,a
        asr     #$1,a,a
        move    a,x1                    ; mid
        move    x:(r7+$35),a
        sub     x0,a
        asr     #$1,a,a
        move    a,x0                    ; side
        move    x:(r7+$2b),y1           ; side gain / 2
        mpy     x0,y1,a
        asl     #$1,a,a                 ; the halving undone in the guard bits
        move    a,y0                    ; scaled side
        move    x1,a
        add     y0,a                    ; mid + side
        move    a,x:(r7+$35)
        move    x1,a
        sub     y0,a                    ; mid - side
        move    a,x:(r7+$36)
; ---- MIX and write back --------------------------------------------------
        move    x:(r7+$35),a
        move    x:(r0),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$20),y1           ; m
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r0)
        move    x:(r7+$36),a
        move    x:(r0+n0),b
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$20),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r0+n0)
; (the send taps left with the sends, 12 Sep 2026: the stations have had no
; send since the one-aux rig; the returns below still need the bus)
; (the return moved to the top of the loop, 13 Sep 2026)
        move    (r0)+n0                 ; the frame advance: n0 is 1 for the
        move    (r0)+n0                 ; whole loop, so two steps, no reload
ch_end:
        nop
        rts

; ===========================================================================
; BYPASS: frames untouched -- nothing to do at all (Spectrum's shape)
; The loop that sat here (14 Sep 2026) added the returns at a level it had
; just tested to be 0: ch_bypass is reached only through the RET test
; above, so its per-sample gate was always taken and it only walked r0.
; ===========================================================================
ch_bypass:
        rts

; ---------------------------------------------------------------------------
; chtube -- DaTube per channel (JClones_DaTube.jsfx, MIT; 13 Sep 2026).
; In: a = x, r3 -> the DC blocker's x1 (x:(r3)) and y1 (x:(r3+$1)). Out: b.
;   xin = x*(0.5 + d)                           ($4c = (0.5+d)/2, halved)
;   u   = 1 - |xin|      (may go negative: the JSFX's linear extension past
;                         +-1 is exactly the curve with u^P dropped, so the
;                         table lookup clamps u to 0 and the rest is linear)
;   T   = u - u^P, P = ln(10) + 1 = 3.3026     (TUBE_UP: 17 pairs of u^P/2)
;   y   = xin + (d/2)*T for xin > 0, xin - d*T for xin < 0   (asymmetric: the
;                         negative half is driven twice as hard -- the tube)
;   out = 2 * y * comp(d), then the DC blocker (k 1, R 0.999).
; Everything runs HALVED (xin/2 <= 0.75, u/2, T/2, y/2) and the post gain is
; comp/4 doubled back twice. STRAIGHT-LINE: no branch. Every mpy x0,y1 (the
; audited-signed order; the one Tcc reads the tst right before it). Clobbers
; x0, x1, y0, y1, a, b, n1, n2; $49 parks u/2.
chtube:
        move    a,x0                    ; x
        move    x:(r7+$4c),y1           ; (0.5 + d)/2
        mpy     x0,y1,a
        move    a,x1                    ; xin/2  (|.| <= 0.75)
        abs     a
        neg     a
        add     #>$400000,a             ; u/2 = 0.5 - |xin/2|, in [-0.25, 0.5]
        move    a,x:(r7+$49)            ; park u/2
        move    #$0,x0                  ; (a move does not disturb the flags)
        tst     a
        tmi     x0,a                    ; the lookup's argument: max(u, 0)/2
        move    a,b
        asr     #$11,b,b                ; u/2 >> 17 = 2*idx + bit 17 ...
        and     #>$fffffe,b             ; ... masked to 2*idx (17 pairs, 1/32 steps)
        move    b1,n1
        move    b1,n2
        move    a,b
        and     #>$3ffff,b              ; the 18 bits under the step (b2 = 0)
        asl     #$5,b,b                 ; frac, Q23
        move    b,x0                    ; AGU settle: n1 written 4 back
        move    p:(r1+n1),y0            ; P2[idx] = u^P / 2
        move    p:(r2+n2),y1            ; P2[idx+1] - P2[idx]  (>= 0)
        mpy     x0,y1,a                 ; frac * slope
        add     y0,a                    ; u^P / 2
        move    x:(r7+$49),b            ; u/2
        sub     a,b                     ; T/2 = (u - u^P)/2
        move    b,x0                    ; T/2
        move    x:(r7+$38),y1           ; d
        mpy     x0,y1,a                 ; d * T/2
        neg     a
        move    a,y0                    ; the negative half's term, parked
        move    x:(r7+$37),y1           ; d/2
        mpy     x0,y1,a                 ; the positive half's term
        move    x1,b                    ; xin/2
        tst     b                       ; its sign -- nothing between this
        tmi     y0,a                    ; and the Tcc (the flag trap)
        add     x1,a                    ; y/2 = xin/2 + term
        move    a,x0
        move    x:(r7+$39),y1           ; comp/2
        mpy     x0,y1,a                 ; (y/2)(comp/2) = y*comp/4
        asl     #$3,a,a                 ; *8 -> 2*y*comp (JClones' output ~2x)
        move    a,x0                    ; x, the DC blocker's input (LIMITING)
        move    x:(r3),x1               ; x1
        move    x0,x:(r3)               ; x1 <- x
        move    x:(r7+$46),y1           ; k = 1.0
        mpy     x1,y1,b                 ; k*x1 (mpysu: y1 is positive)
        move    x0,a
        sub     b,a                     ; x - x1
        move    x:(r3+$1),x0            ; y1
        move    x:(r7+$47),y1           ; R = 0.999
        mac     x0,y1,a                 ; + R*y1
        move    a,x:(r3+$1)             ; y1 <- y
        move    a,b
        rts

; ---------------------------------------------------------------------------
; chinfl -- OInflator per channel (JClones_OInflator.jsfx, MIT; 13 Sep 2026),
; single band, Curve at the JSFX default 0 (c = 0.25), Clip on (the +-0.5
; threshold on the halved signal IS the input's full scale). In: a = x. Out: b.
;   x2 = x/2                      (the JSFX's 0.5 input headroom)
;   g  = 0.75 + 0.5*|x2|          (2c|x2| + (1 - c), in [0.75, 1])
;   gx = g*x2                     (|gx| <= 0.5)
;   y  = 2e*gx*(1 - |gx|) + (1 - e)*x2
;   out = 2*y                     (the JSFX's x2 output gain; |out| <= 1)
; e = DRV/128 ($3a = e/2, $3b = 1 - e). g and t = 1 - |gx| live halved.
; STRAIGHT-LINE, stateless; every mpy/mac x0,y1. Clobbers x0, x1, y1, a, b.
chinfl:
        asr     #$1,a,a                 ; x2
        move    a,x1
        abs     a
        move    a,x0                    ; |x2|
        move    #$20,y1                 ; 0.25
        mpy     x0,y1,a
        add     #>$300000,a             ; g/2 = 0.375 + 0.25*|x2|
        move    a,y1
        move    x1,x0                   ; x2
        mpy     x0,y1,a
        asl     #$1,a,a                 ; gx = g*x2
        move    a,x0                    ; gx
        abs     a
        asr     #$1,a,a
        neg     a
        add     #>$400000,a             ; t/2 = 0.5 - |gx|/2, in [0.25, 0.5]
        move    a,y1
        mpy     x0,y1,a                 ; gx * t/2
        move    a,x0
        move    x:(r7+$3a),y1           ; e/2
        mpy     x0,y1,a                 ; gx * t/2 * e/2
        asl     #$3,a,a                 ; 2e * gx * t
        move    x1,x0                   ; x2
        move    x:(r7+$3b),y1           ; 1 - e
        mac     x0,y1,a                 ; + (1 - e)*x2 = y
        asl     #$1,a,a                 ; out = 2y
        move    a,b
        rts

; ---------------------------------------------------------------------------
; chtape -- TapeHead per channel (JClones_TapeHead.jsfx, MIT; 13 Sep 2026).
; In: a = x, r3 -> y1 (x:(r3)) and y2 (x:(r3+$1)), both kept at /4 (the
; port's headroom: |y1| <= 1.46, |y2| <= 1.95 true). Out: b = (g3*clip(y3)
; + ss(d*y1) + ss(d*y2)) * trim, up to 2.2 -- the caller's store clips it,
; which is the JSFX's own output clip. STRAIGHT-LINE: no branch of any kind
; (cycle_count.py charges the span at each call). Every mpy is x0,y1 (the
; audited-signed order); every clip is a LIMITING move into x0. Clobbers
; x0, x1, y1, a, b.
;   y1 += k2*y2 ; y3 = k1*y1 + y2 - x ; y2 -= k3mag*y3      (k3 = -1.4 k2)
;   ss(v) = 1.5v - 0.5v^3 on v = clip(d*y1), clip(d*y2)      (v = 32*(y1/4*d/8))
chtape:
        asr     #$2,a,a                 ; Xs = x/4
        move    a,x1
        move    x:(r3+$1),x0            ; y2
        move    x:(r7+$30),y1           ; k2
        mpy     x0,y1,a
        move    x:(r3),b
        add     b,a                     ; y1n = y1 + k2*y2
        move    a,x0
        move    x0,x:(r3)
        move    #>$5b6db7,y1            ; k1 = 5/7
        mpy     x0,y1,a
        move    x:(r3+$1),b
        add     b,a
        sub     x1,a                    ; y3 = k1*y1n + y2 - Xs
        move    a,x0
        move    x:(r7+$31),y1           ; k3mag
        mpy     x0,y1,a
        move    x:(r3+$1),b
        sub     a,b                     ; y2n = y2 - k3mag*y3
        move    b,x:(r3+$1)
        move    x0,a
        asl     #$2,a,a                 ; 4*y3
        move    a,x0                    ; LIMITING move: clip(y3)
        move    #>$33e5de,y1            ; |g3|*trim/2
        mpy     x0,y1,b
        asl     #$1,b,b
        neg     b                       ; b = g3*trim*clip(y3)   (g3 < 0)
        move    x:(r3),x0               ; y1n/4
        move    x:(r7+$48),y1           ; d/8
        mpy     x0,y1,a
        asl     #$5,a,a                 ; v = d*y1n
        move    a,x0                    ; LIMITING move: clip(v)
        move    x0,y1
        mpy     x0,y1,a                 ; v^2
        move    a,y1
        mpy     x0,y1,a                 ; v^3
        neg     a
        add     x0,a                    ; v - v^3
        asr     #$1,a,a
        add     x0,a                    ; ss(v) = 1.5v - 0.5v^3
        move    a,x0
        move    #>$59999a,y1            ; trim 0.7
        mpy     x0,y1,a
        add     a,b
        move    x:(r3+$1),x0            ; y2n/4
        move    x:(r7+$48),y1
        mpy     x0,y1,a
        asl     #$5,a,a
        move    a,x0
        move    x0,y1
        mpy     x0,y1,a
        move    a,y1
        mpy     x0,y1,a
        neg     a
        add     x0,a
        asr     #$1,a,a
        add     x0,a
        move    a,x0
        move    #>$59999a,y1
        mpy     x0,y1,a
        add     a,b
        rts
