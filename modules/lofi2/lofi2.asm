; ---------------------------------------------------------------------------
; LOFI2 -- one modulator, then sample-rate and bit reduction.
;
; STAGE 4 OF 4 -- COMPLETE. Ring mod OR stereo frequency shifter, then SRR
; and BRR, then a high-shelf cut. Stock's quantiser, stock's hold curve and
; stock EQUALIZER's HIGH shelf, all three ported. The chain is
;   dry -> modulator -> MIX -> SRR -> BRR -> LPF -> out,
; which is Bryan's stated order: the hold and the crush see the MODULATED
; signal, so the reduction aliases the ring output rather than the dry. MIX is
; the MODULATOR's depth and sits before the reduction pair, so SRR and BRR are
; live at MIX=0 -- see the MIX block below.
;
;   stage 1  spine + MIX                    done
;   stage 2  SRR + BRR                      done
;   stage 3  ring mod, RANGE and AMPH       done
;   stage 4  stereo frequency shifter, FDBK done
;
; All three MODE positions are implemented: 0 runs the ring block, 1 and 2 run
; the shifter with a per-block sign on Q. The two modulators are mutually
; exclusive and each is skipped by a forward branch.
;
; Same contract as ripple_svf.asm / warp_fold.asm / character.asm: a per-track
; INSERT reading x:(r0) / x:(r0+n0) and writing back in place, n7 frames, no
; bus, no absolute Y, all state in this instance's r7 block.
;
; ---- knobs ----------------------------------------------------------------
;   p0 FREQ   carrier frequency, EXPONENTIAL, six octaves from RANGE's base
;   p1 MIX    modulator depth only: crossfades ring/shift against dry.
;             SRR and BRR run after it and are LIVE AT MIX=0.
;   p2 FDBK   SHIFT: feedback, the f/f+d/f+2d ladder
;        GAIN   RING: makeup gain on the ring product, 2^(k/64): 0 dB at 0,
;             +6 dB at 64, +11.9 dB at 127 (the panel renames the slot per
;             MODE; one knob word, read per mode)
;   p3 SRR    sample-rate reduction: stock LO-FI's own curve, 44100 Hz
;             down to 1782 Hz; 0 = off
;   p4 BRR    bit depth, CONTINUOUS round-to-nearest -- stock LO-FI's own
;             quantiser and its X:0x7400 table, ported
;   p5 LPF    high-shelf cut, LAST in the chain: stock EQUALIZER's HIGH
;             shelf with GN fixed at -32. 127 = no impact, turning down
;             walks the corner into the band
;   p6 RANGE  MODE-DEPENDENT base: RING 2 Hz / 60 Hz (MF-102), SHIFT 2 Hz /
;             31.25 Hz (Bode 1630) -- knob field of r6+$c
;   p8 MODE   0 RING, 1 SHIFT DOWN, 2 SHIFT UP -- knob field of r6+$d
;   p10 AMPH  ring carrier L/R phase offset, BIPOLAR: -90..+90 deg, 0 at
;             the knob's centre (64); + puts R ahead, - puts L ahead. Knob
;             field of r6+$e
;
; ---- r7 slots -------------------------------------------------------------
;   the MODE duck:
;     $10 running mode (PERSISTENT: the mode actually playing)
;     $11 duck depth e, 0 = none .. $7fffff = wet fully out (PERSISTENT)
;     $12 ring GAIN / 4 (per block)   $13 duck step, signed (per block)
;     $14 m*(1-e), the MIX the crossfade uses (per sample)
;     $15 MODE as the knob has it (per block)
;   persistent (Character's slots for the same jobs, so the two read alike):
;     $19 held L      $1a held R      $1b srr accum      $1c carrier phase
;   per block:
;     $20 m = MIX     $21 range       $22 mode
;     $24 carrier step   $25 srr threshold  $26 amph offset  $27 ring flag
;     $28/$29 s low/high     $2a/$2b 1/s low/high  (48-bit, BRR)
;     $1d c0 TARGET  $1e c1  $1f c2  (LPF shelf)   $23 index scratch
;     $3f c0 IN USE -- smoothed toward $1d one step per sample (PERSISTENT)
;     $2c sin  $2d cos  $2e I_L $2f Q_L $30 I_R $31 Q_R  $32 shift flag
;     $37 sign  $38 fdbk  $39/$3a aPrev L/R  $3b/$3c lastwet L/R
;     $3d/$3e chain inputs L/R
;   the four Hilbert chains, 16 words each -- ALL above $3f, so all in the
;   two-word long form, which is deliberate: they are the cold state and
;   the hot scalars keep the short encodings below:
;     $40 A-L   $50 B-L   $60 A-R   $70 B-R      (ends at $7f)
;   the LPF shelf's persistent state, two words per channel:
;     $80/$81 allpass state and in[n-1], L    $82/$83 the same, R
;   $84..$8a is host-owned for state ACROSS CALLS and per-call scratch there
;   is fine (CHIP.md, bisected; the blanket "$84+ hangs" was retracted
;   30 Aug 2026 and BusDelay ships using $84..$88).
;   Each section is y[n-2], y[n-1], x[n-2], x[n-1] IN THAT ORDER -- chosen so
;   r1's read walk and r2's write walk are both monotonic. Do not reorder.
;   per sample scratch:
;     $33 dry L       $34 dry R       $35 v L            $36 v R
; All below $40: a displacement past 63 assembles to the two-word long form.
; The four Hilbert chains are 16 words each, 64 in total, and go above that
; line for exactly that reason.
;
; ---- boot garbage --------------------------------------------------------
; Until the port to the October 2026 tree `init` was a bare `rts`, after
; WarpFold's note that r7 is not reliably set at init on hardware. Stock
; LO-FI's own init zeroes its block from r7, and so do this tree's modules
; under verify_dirtystate, so `init` now zeroes $00..$83. The tolerances
; below still hold and are kept:
;   * carrier phase: any value is a legal phase, and A1 extraction wraps it.
;   * held pair: at worst one wrong sample before the first latch.
;   * SRR phase: NOT self-correcting -- a negative value never reaches the
;     wrap threshold and the hold would stick forever -- so it is still
;     sanitised with one AND per block, not per sample.
;
; CYCLES_FORWARD_BRANCHES
; Every conditional branch in the sample loop jumps FORWARD and can only
; SKIP code, so the word span remains a ceiling: the SRR hold's `blt`, and
; the two modulator gates. A backward one would be a loop the span counts
; once, which is the thing that declaration must never be used to hide.
;
; Every mpy is `mpy x0,y1` or `mpy y0,x0` -- the two operand orders dsp_asm
; is known to encode SIGNED. AND and ASL leave A2 STALE and a store would
; then saturate, so every value passing through one leaves via a1 into a
; clean register first.
; ---------------------------------------------------------------------------

init:
; ---- every slot to zero (verify_dirtystate; AGENTS.md "a persistent slot
; that init does not clear"). r5, never r1: the FX1 dispatcher keeps the
; effect id in r1 across this call (verify_initregs). $00..$83 is the whole
; block, so no per-slot census can go stale. The smoothed shelf coefficient
; at $3f starts at 0 and glides to its target over the first few hundred
; samples, which on silence produces nothing.
        clr     a
        move    r7,r5
        move    #>$ffffff,m5
        do      #$84,>lfiniz
        move    a,x:(r5)+
lfiniz:
        nop
; start fully ducked: the first block takes the knob's MODE and fades the
; wet in over the duck's 5 ms instead of starting it with a step
        move    #>$7fffff,x0
        move    x0,x:(r7+$11)
        rts

proc:
; ---- per-block knob decode ------------------------------------------------
        move    x:(r6+$1),a             ; m = MIX, value<<16
        and     #>$7f0000,a             ; knob field only: an LFO dirties bits 8-15
        move    a1,x0
        move    x0,x:(r7+$20)

        move    x:(r6+$c),a             ; RANGE, slot 6, knob field
        and     #>$7f0000,a
        move    a1,x0
        move    x0,x:(r7+$21)

        move    x:(r6+$d),a             ; MODE, slot 8, knob field
        and     #>$7f0000,a
        move    a1,x0
        move    x0,x:(r7+$15)           ; MODE as the knob has it

; ---- the MODE duck --------------------------------------------------------
; A MODE change swaps one modulator for an unrelated one (or flips Q's sign),
; a step in the output. So the wet is ducked to dry over 5 ms, the running
; mode switches only once it is fully out, and the wet comes back over 5 ms.
; Only the running mode ($10) reaches the flags below, never the knob. The
; switch waits for a block boundary, so the wet may sit out for up to one
; block (16 samples) longer. MIX then runs at m*(1-e), exactly m when e = 0.
        move    x:(r7+$11),a            ; e
        move    #>$7fff00,x1
        sub     x1,a                    ; >= 0: fully ducked
        move    x:(r7+$10),b            ; the running mode
        tpl     x0,b                    ; fully ducked: take the knob's
        move    b,x:(r7+$10)
        move    b,x:(r7+$22)            ; every flag below reads THIS
        move    x:(r7+$15),a
        sub     b,a                     ; knob - running; Z when they agree
        move    #>$949c,b               ; +1/220.5 a sample: duck
        move    #>$ff6b64,y1            ; -1/220.5 a sample: recover
        teq     y1,b
        move    b,x:(r7+$13)

; shift flag: 1 in MODE 1 and 2. Resolved at block setup with the ring flag.
        move    x:(r7+$22),a
        tst     a
        beq     lf_noshf
        move    #>$1,a
        bra     lf_shf
lf_noshf:
        clr     a
lf_shf:
        move    a,x:(r7+$32)

; s: -1 for MODE 1 (DOWN), +1 for MODE 2 (UP). A per-block sign on Q, so
; the direction never costs a branch in the sample loop.
; Selector order is RING / DOWN / UP, so the encoder walks the sidebands in
; pitch order with RING at one end. Nothing else reads MODE's value: the ring
; flag tests it for zero and the shift flag for nonzero, so this compare is
; the only place the two shift positions are told apart.
        move    x:(r7+$22),a
        move    #>$20000,x0
        cmp     x0,a                    ; MODE 2?
        beq     lf_up
        move    #>$800000,x0            ; MODE 1 = DOWN
        bra     lf_sgn
lf_up:
        move    #>$7fffff,x0            ; MODE 2 = UP
lf_sgn:
        move    x0,x:(r7+$37)

; fdbk = FDBK * 0.45, BodeShift's cap. Inactive in RING by design: ring
; feedback is a harmonic-order generator, not a ladder, and was not wanted.
        move    x:(r6+$2),a
        and     #>$7f0000,a
        move    a1,x0
        move    #>$39999a,y1
        mpy     x0,y1,a
        move    a,x:(r7+$38)

; GAIN = 2^(k/64) on the same knob word, read only by the RING block. Stored
; as GAIN/4 (it reaches 3.96) and restored there with asl #2. k/64 = n + f:
; n is bit 23 of the doubled knob word, f the 23 bits below it, and
; 2^f = 1 + 0.66023 f + 0.33977 f^2 (exact at 0 and 1, within 0.023 dB
; between). h = 2^f / 2; GAIN/4 = h at n = 1, h/2 at n = 0. GAIN 0 is
; therefore exactly 0.25 * 4: unity, bit-exact.
        move    x:(r6+$2),a
        and     #>$7f0000,a
        asl     #$1,a,a                 ; k/64: bit 23 = n, bits 22-0 = f
        move    a1,x1
        move    x1,a
        and     #>$7fffff,a
        move    a1,x0                   ; f
        move    #>$2a4135,a             ; 0.66023/2
        move    #>$15becb,y1            ; 0.33977/2
        mac     x0,y1,a                 ; 0.33012 + 0.16989 f
        move    a,y1
        move    #>$400000,a             ; 0.5
        mac     x0,y1,a                 ; h = 2^f / 2
        move    a,x0
        asr     #$1,a,a
        move    a,y0                    ; h/2
        move    x1,b
        tst     b                       ; N: n = 1
        move    y0,a
        tmi     x0,a
        move    a,x:(r7+$12)            ; GAIN/4

; ring flag: 1 only in MODE 0. Resolved HERE, at block setup -- a dispatch
; inside the sample loop could not be priced by tools/cycle_count.py.
        move    x:(r7+$22),a
        tst     a
        bne     lf_noring
        move    #>$1,a
        bra     lf_ringf
lf_noring:
        clr     a
lf_ringf:
        move    a,x:(r7+$27)

; ---- BRR -> stock LO-FI's quantiser coefficients ------------------------
; PORTED FROM STOCK, not from Character. Character's CRSH is a truncating
; power-of-two MASK: 22 integer depths over 128 knob positions, and it floors,
; which biases every sample toward zero. Stock LO-FI is a CONTINUOUS
; round-to-nearest quantiser, y = round(x*s)/s, and it is the control LOFI2 is
; meant to improve on -- shipping a coarser one was a regression I introduced.
; Read from payload A at P:0x01c84 (block) and func_001cac (loop).
;
;   u   = 1 - 0.78125*(BRR/128)          the maci; $9c0000 IS -0.78125
;   t   = 1 - u^2                        quadratic, NOT logarithmic
;   idx = t * $5c00, split 10/14: low 10 bits index a 1024-word table,
;                                 the rest is a power-of-two shift count
;
; The table at X:0x7400 is read FORWARD for s and BACKWARD from $77ff for
; 1/s: through an exponential table the two exponents sum to a constant, so
; one table yields a mantissa and its reciprocal. Mantissa from the table,
; exponent from the shift -- which is where "bits = -log2(value)" comes from.
; Confirmed at the same absolute X address in BOTH payloads.
;
; ⚠️ Both coefficients are 48-BIT. s can be large where the steps are fine,
; and a 24-bit product would lose exactly the precision the fine end needs,
; so a0/a1 and b0/b1 are all kept and the loop does double-precision.
        move    x:(r6+$4),a
        and     #>$7f0000,a
        move    a1,x0
        move    #>$7fffff,a
        maci    #>$9c0000,x0,a          ; u = 1 - 0.78125*k
        move    a,x0
        mpy     x0,x0,a                 ; u^2
        add     #>$800000,a             ; u^2 - 1
        neg     a                       ; t = 1 - u^2
        move    a,x1
        mpyri   #>$5c00,x1,a            ; the table index
        asr     #$a,a,b                 ; b1 = shift count
        and     #>$3ff,a                ; a1 = 10-bit fraction
        move    a1,y0                   ; frac
        move    b1,x0                   ; shift count

; ⚠️ Stock reaches the table with x:(r3+n3) and x:(r2+$7400) after setting
; m2/m4 for modulo addressing. Offset-by-Nn addressing IS modulo-controlled,
; and we do not know what the host leaves in m3. So both addresses are
; computed WHOLE into r2/r3 and read with plain register-indirect, which no
; m register touches. Costs four instructions per block and removes the
; assumption entirely.
        move    #>$7400,a
        add     y0,a
        move    a1,r2                   ; forward:  $7400 + frac
        move    #>$77ff,a
        sub     y0,a
        move    a1,r3                   ; backward: $77ff - frac

        move    x:(r3),a                ; 1/s mantissa
        asr     #$17,a,a
        asl     x0,a,a                  ; scaled up by the exponent
        neg     a
; ⚠️ 13 Sep 2026: the x4 correction USED to live here as `asl #$2,a,a` on the
; reciprocal coefficient. Confirmed against payload A's func_001c84 block
; (bare, un-annotated disassembly, this session): stock has NO such shift
; anywhere in this sequence -- it goes straight from `asl x0,a,a` to `neg a`.
; So the x4 shift was never a port of stock behaviour; it was compensation
; for taking the quantiser out of stock's surrounding pipeline (the input
; FIR at func_001cc6 most likely carries the gain in context), bolted onto
; a coefficient that was never meant to carry it. Sweeping BRR confirmed
; the failure mode directly: flat ~1.0 through BRR 63, then 1.7875 at 127 --
; an overflow as the reciprocal's mantissa grows into a shift count the
; extra x4 was never checked against. MOVED to the loop's final `asl #$17`
; -> `#$19` instead (see below), so this block is now byte-identical to
; stock's func_001c84 -- same numbers stock uses, so it cannot overflow any
; differently than stock's own quantiser does at any BRR position.
        move    x:(r2),b                ; s mantissa
        asr     x0,b,b                  ; scaled down by the exponent
        neg     b                       ; both negated: the signs cancel in
                                        ; the product, exactly as stock leaves
                                        ; them
        move    b0,x:(r7+$28)           ; s   low
        move    b,x:(r7+$29)            ; s   high -- LIMITED move, as stock's
                                        ; `move b,y:(r4)+` at 001ca2. At BRR=0 the
                                        ; table entry is exactly -1.0 and `neg b`
                                        ; yields +1.0, which needs the limiter;
                                        ; b1 raw would write $800000 and invert.
        move    a0,x:(r7+$2a)           ; 1/s low
        move    a,x:(r7+$2b)            ; 1/s high -- LIMITED, as stock's 001ca4

; ---- LPF -> stock EQUALIZER's HIGH-shelf coefficients ---------------------
; PORTED FROM STOCK, from EQUALIZER's coefficient block at func_000bfa in
; payload A. Not a design of ours: the arithmetic, the tables, the index
; resolution and the #$8 immediates are all stock's, with exactly three
; deliberate departures, all agreed:
;
;   1. GN is FIXED at 32 (stock's bipolar -32), so both gain-indexed reads
;      are at constant addresses. Stock recomputes them from the knob.
;   2. The PEAKING section is not ported at all. In stock, TYP selects
;      nothing: BOTH sections always run, and HIGH simply forces the peak's
;      gain word to $40 so it passes unity. With GN2 neutral there is
;      nothing for that section to do, so it is omitted rather than run.
;   3. Coefficients SNAP per block. Stock smooths them into absolute Y and
;      streams y:(r4)+ per sample; we declare ybase=NEVER and that is what
;      keeps this module eligible for an FX1 row. If a FRQ sweep clicks,
;      the fix is a smoother in r7 state, not absolute Y.
;
; The arithmetic, as stock does it:
;
;   i  = T[$13c7 + 4*FRQ] - T[$1c59 + GN]     HIGH subtracts; LOW adds
;   c0 = T[$15c7 + i]                         the allpass coefficient
;   g  = T[$1bd9 + GN]
;   c1 = g + 0.0625        c2 = 0.0625 - g    HIGH; LOW is g - 0.0625
;
; ⚠️ `docs/firmware/TABLES.md` calls $13c7 and $1c59 "trim" tables and reads
; their contents as ~3e-5 and ~1e-5 CORRECTION TERMS. They are not
; corrections. Stock puts their difference straight into r3 and indexes
; $15c7 with it: they are INTEGER INDEX tables that happen to look tiny read
; as fractions (3e-5 in Q23 is about 250). So the frequency index is warped
; by the gain, which is what a first-order shelf needs. Correct that file.
;
; FRQ indexes with FOUR TIMES a normal knob's resolution -- `asr #$e` on a
; value<<16 word, not `asr #$10`. Unexplained but stock, and kept, which is
; also why the knob needs no remapping to hold stock's range.
;
; ⚠️ THE FOUR TABLE ADDRESSES BELOW ARE PAYLOAD A'S and are rewritten by the
; build. They sit in the curve bank, which is at X:0x438 on payload A and
; X:0x42b on payload B -- 13 words apart, because the X block under it is 23
; words on A and 10 on B. Stock needs no mechanism for this: each payload is
; separately linked, so EQUALIZER reads `x:(r3+$13c7)` on A and
; `x:(r3+$13ba)` on B, same opcode, different extension word. A module is one
; source assembled into both, so `DspSection.xtables` in manifest.py declares
; these and build_bus.py substitutes per payload.
; Consequence: a COMMENT here naming $1c59 or $1bd9 describes payload A only.
; Read the emitted disassembly, not this header, for what payload B runs.
; The fault that produced all of this (13 Sep 2026): with A's addresses baked
; into both payloads, tracks 1-4 ran the whole LPF travel about three times
; too bright, and at knob 125-127 the $13c7 read ran past the end of its
; 512-word table into $7ffffe, putting 0x8015ab in r3 -- off the end of
; anything the image uploads. Knobs 125 and 126 landed on the SAME bogus
; address and sounded identically dull; 127 landed one word away and passed.
; Tracks 5-8 were correct throughout, and no render ever showed it, because
; dsp_host boots payload A.
;
; ⚠️ Every table address is computed WHOLE into r3 and read with plain
; register-indirect, for the same reason the BRR block does it: stock reaches
; these with r3+displacement, displacement addressing goes through the AGU,
; and we do not know what the host leaves in m3.
; ⚠️ The AND is NOT stock's -- stock goes straight from the read to `asr #$e`.
; It is here because `asr #$e` on a value<<16 word KEEPS BITS 14 AND 15, so
; anything the host leaves below the knob field lands directly in the table
; index. At knob resolution those bits fall off the bottom and no other read
; in this file cares; here they are worth up to three table entries, and at
; the top of the curve one entry is several hundred Hz. Symptom on hardware
; (repeatable, RING and both SHIFT modes, invisible in every render because
; dsp_host pokes r6 directly): LPF 125 and 126 sounded like a far lower knob
; setting while the rest of the sweep measured correctly.
; The other three reads in this block (RANGE, MODE, AMPH) already mask; this
; one did not because it was ported from stock, where the read is clean.
        move    x:(r6+$5),a             ; LPF knob, value<<16
        and     #>$7f0000,a             ; knob field ONLY -- see above
        move    a1,a
        asr     #$e,a,a                 ; stock's index: knob x 4
        move    a1,x0
        move    #>$13c7,a
        add     x0,a
        move    a1,r3
        move    x:(r3),a                ; the frequency index term
        move    a1,x:(r7+$23)           ; park it: r3 is needed again
        move    #>$1c79,a               ; $1c59 + 32, GN fixed
        move    a1,r3
        move    x:(r3),x0               ; the gain index term
        move    x:(r7+$23),a
        sub     x0,a                    ; HIGH SUBTRACTS. LOW would add here,
        move    a1,x0                   ;  and that is the whole difference
        move    #>$15c7,a               ;  between the two shelf directions
        add     x0,a
        move    a1,r3
        move    x:(r3),a
        move    a1,x:(r7+$1d)           ; c0 TARGET -- the loop walks $3f
                                        ;  toward this, it is not used direct
        move    #>$1bf9,a               ; $1bd9 + 32, GN fixed
        move    a1,r3
        move    x:(r3),x0               ; g
        move    #>$080000,y0            ; 0.0625 -- stock's #$8 immediate
        move    x0,a
        add     y0,a
        move    a1,x:(r7+$1e)           ; c1 = g + 0.0625
        move    y0,a
        sub     x0,a
        move    a1,x:(r7+$1f)           ; c2 = 0.0625 - g

; ---- SRR -> stock LO-FI's hold THRESHOLD ---------------------------------
; PORTED FROM STOCK (payload A, P:0x01c56 + func_001cba). The mechanism I
; built independently was already the right one -- a fractional hold with an
; accumulator and a wrap -- but with the roles inverted: I varied the rate
; against a fixed threshold, stock varies the THRESHOLD against a fixed
; increment of $10. Equivalent arithmetic, different taper, and stock's is
; the one that matters:
;
;   t = 128*v                     (the knob word, asr 9)
;   t = (t + $4000)^2
;   t = (t - 32)*4 + 16
;
; threshold runs 16 at knob 0 to 396 at 127, and the hold is threshold/16 --
; exactly 1 sample at the bottom, 24.75 at the top. 44100/24.75 = 1782 Hz,
; matching the hardware-confirmed floor in our notes to the digit.
;
; Beyond correctness this makes the MUSICAL NOTE-MAPPING TABLE from prior
; work valid for LOFI2's knob, because the curve is now the same one it was
; measured against. Against my invented curve that table meant nothing.
        move    x:(r6+$3),a
        and     #>$7f0000,a
        move    a1,a                    ; clean A2/A0 before the shift
        asr     #$9,a,a
        add     #>$4000,a
        move    a,x0
        mpy     x0,x0,a
        sub     #>$20,a
        asl     #$2,a,a
        move    #>$10,x0
        add     x0,a
        move    a,x:(r7+$25)            ; the threshold

        move    x:(r7+$1b),a            ; sanitise the SRR phase once
        and     #>$3fffff,a
        move    a1,x0
        move    x0,x:(r7+$1b)

; ---- FREQ -> carrier step, SIX OCTAVES, EXPONENTIAL ----------------------
; The MF-102's ranges are 2-130 Hz and 60-4000 Hz, both six octaves, so the
; taper is exponential -- constant cents per degree of rotation. Neither
; BodeShift nor Character has this; both use squared tapers, which cramp the
; bottom of a carrier knob and coarsen the top.
;
; step is WarpFold's convention: the phase spans the full 24 bits as one
; cycle, so a Q23 value of 1.0 is half a cycle and step = 2*f/fs.
;   base step, f=0:  LOW  2 Hz -> $0002f9      HIGH 60 Hz -> $00593d
;
; ⚠️ NO ZERO. FREQ=0 is the base frequency, not silence. Character's
; "skip the multiply at step 0" gate does not apply and the cycle count must
; assume the carrier always runs.
; The base depends on MODE as well as RANGE, because the two effects have
; different ancestors. RING follows the MF-102: 2-130 Hz and 60-4000 Hz.
; SHIFT follows the Bode 1630, whose exponential scale is 2 Hz to 2 kHz --
; so LOW keeps the same 2 Hz floor and HIGH starts at 31.25 Hz, six octaves
; from which is exactly 2000 Hz. The 1630's four LINEAR scales are
; deliberately not offered: MODE already picks the direction they exist for.
        move    x:(r7+$32),a            ; shift?
        tst     a
        bne     lf_sbase
        move    x:(r7+$21),a            ; RING bases
        tst     a
        beq     lf_rlow
        move    #>$00593d,x0            ; HIGH: 60 Hz
        bra     lf_rdone
lf_rlow:
        move    #>$0002f9,x0            ; LOW: 2 Hz
        bra     lf_rdone
lf_sbase:
        move    x:(r7+$21),a            ; SHIFT bases
        tst     a
        beq     lf_slow
        move    #>$002e71,x0            ; HIGH: 31.25 Hz -> 2 kHz at the top
        bra     lf_rdone
lf_slow:
        move    #>$0002f9,x0            ; LOW: 2 Hz
lf_rdone:
        move    x0,x:(r7+$24)           ; park the base step

; t = 0.75 * knob, so the six octaves land in bits 22..20 (integer) and the
; rest is the fraction. The knob word IS knob/128, so t = 6*knob/128 / 8.
        move    x:(r6+$0),a
        and     #>$7f0000,a
        move    a1,x0
        move    #>$600000,y1            ; 0.75
        mpy     x0,y1,a
        move    a1,x1                   ; t

        move    x1,a                    ; n = whole octaves, 0..5
        and     #>$700000,a
        move    a1,x0
        move    x0,a
        asr     #$14,a,a
        move    a1,y0                   ; the octave shift count

        move    x1,a                    ; f = fractional octave, back to [0,1)
        and     #>$0fffff,a
        move    a1,x0
        move    x0,a
        asl     #$3,a,a
        move    a1,x1                   ; f

; h = 2^f / 2, quadratic: 0.5 + f*(0.328125 + f*0.171875). Halved because
; 2^f reaches 2.0, which Q23 cannot hold; the octave shift below puts it
; back. The coefficients sum to exactly 1.0 so h(1) = 1.0 exactly and the
; octave boundaries are seamless. Worst-case error is about 5 cents near
; f = 0.25 -- inaudible on a carrier, and the alternative is a cubic.
        move    x1,x0
        move    #>$160000,y1            ; 0.171875
        mpy     x0,y1,a
        add     #>$2a0000,a             ; + 0.328125
        move    a,y1
        move    x1,x0                   ; f
        mpy     x0,y1,a
        add     #>$400000,a             ; + 0.5
        move    a,y1                    ; h, in [0.5, 1.0)

; step = base * h, then shifted up (n+1) times: the +1 undoes h's halving.
        move    x:(r7+$24),x0
        mpy     x0,y1,a
        asl     #$1,a,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$24)
        move    y0,b                    ; ⚠️ a `do` with a count of 0 runs
        tst     b                       ;  65536 times, so guard it exactly
        beq     lf_noct                 ;  as the mask loop above does
        move    x:(r7+$24),a
        do      y0,>lf_octl
        asl     #$1,a,a
        move    a1,x0
        move    x0,a
lf_octl:
        nop
        move    a,x:(r7+$24)
lf_noct:

; ---- AMPH -> the L/R carrier phase offset --------------------------------
; BIPOLAR (October 2026; 0..~357 degrees before): the phase word spans one
; cycle over 24 bits, so the knob word less $400000 (knob 64) is exactly
; -1/4..+1/4 cycle: -90..+88.6 degrees, 1.4 a step, 0 at the centre. Every
; distinct stereo motion of a ring mod lives inside +-90 (theta and
; 180-theta give the same envelope, lead and lag swapped); the sign says
; which channel leads. Wraps in A1 exactly as the phase itself does.
        move    x:(r6+$e),a
        and     #>$7f0000,a
        sub     #>$400000,a
        move    a1,x0
        move    x0,x:(r7+$26)

; ---- sample loop ----------------------------------------------------------
        move    #>$1,n0
        move    #$40,n1                 ; the Hilbert chains' base offset
        do      n7,>lf_end

; park the dry pair, and default v (the modulated signal) to it
        move    x:(r0),x1
        move    x1,x:(r7+$33)
        move    x1,x:(r7+$35)
        move    x:(r0+n0),x1
        move    x1,x:(r7+$34)
        move    x1,x:(r7+$36)

; MODEFORK_BEGIN -- cycle_count.py: RING and SHIFT are MUTUALLY EXCLUSIVE.
; Without these markers the tool sums both and prices a whole engine that
; can never run on the same sample. BEGIN..first MID is the dispatch.
        nop
; MODEFORK_MID -- alternative 1: RING
; ---- MODULATOR: ring mod, MODE 0 only ------------------------------------
; Forward branch, and it SKIPS work, so the word span is still the worst-case
; cycle count. In MODE 1/2 the carrier does not advance either -- there is no
; continuity to preserve when nothing reads it, and stage 4 gives the shifter
; its own oscillator.
        move    x:(r7+$27),a            ; ring flag
        tst     a
        beq     lf_nomod

; carrier: WarpFold's parabolic sine 4*p*(1-|p|) on a phase wrapped by A1
; extraction -- continuous at the wrap, exact +/-1 peaks.
        move    x:(r7+$24),y0           ; step
        move    x:(r7+$1c),a            ; phase
        add     y0,a
        move    a1,x0                   ; p, wrapped
        move    x0,x:(r7+$1c)
        move    x0,a                    ; clean
        abs     a
        move    #>$800000,y1            ; -1.0
        add     y1,a                    ; |p| - 1
        neg     a                       ; t = 1 - |p|
        move    a,y1
        mpy     x0,y1,a                 ; p*t
        asl     #$2,a,a                 ; carrier L = 4*p*t
        move    a,y1
        move    x:(r7+$33),x0           ; dry L
        mpy     x0,y1,a
        move    a,x0
        move    x:(r7+$12),y1           ; GAIN/4
        mpy     x0,y1,a
        asl     #$2,a,a                 ; x GAIN; the store limits
        move    a,x:(r7+$35)            ; v L

; the R carrier is the same shape read at p + AMPH; at AMPH=0 the offset is
; zero and the two are identical, so this costs cycles rather than a branch
        move    x:(r7+$1c),a
        move    x:(r7+$26),x0           ; amph offset
        add     x0,a
        move    a1,x0                   ; pR, wrapped
        move    x0,a
        abs     a
        move    #>$800000,y1
        add     y1,a
        neg     a
        move    a,y1
        mpy     x0,y1,a
        asl     #$2,a,a                 ; carrier R
        move    a,y1
        move    x:(r7+$34),x0           ; dry R
        mpy     x0,y1,a
        move    a,x0
        move    x:(r7+$12),y1           ; GAIN/4
        mpy     x0,y1,a
        asl     #$2,a,a
        move    a,x:(r7+$36)            ; v R
lf_nomod:


; MODEFORK_MID -- alternative 2: SHIFT (the expensive one: 16 allpass
; sections and two calls into lf_sin, against the ring's single carrier)
; ---- MODULATOR: frequency shifter, MODE 1 (UP) and 2 (DOWN) --------------
; STEREO: two independent Hilbert pairs, one shared oscillator. BodeShift
; computes its analytic pair on (L+R)/4 and gets away with it because WIDE
; derives its stereo from the two DIRECTIONS; with WIDE dropped a mono wet
; would put every shifted partial dead centre and collapse the image
; entirely at MIX=127. So each channel gets its own chain A and chain B.
; Ring mod needs none of this -- one carrier multiplies both channels and
; the image survives untouched.
        move    x:(r7+$32),a            ; shift flag
        tst     a
        beq     lf_noshift

; in = 0.5*dry + fdbk*lastwet, per channel. The halving is what keeps the
; feedback loop inside the rail: |in| settles at 0.5/(1-fdbk), so fdbk < 0.5
; is an ARITHMETIC cap, not a taste one. The x2 at the output undoes it.
        move    x:(r7+$33),a            ; dry L
        asr     #$1,a,a
        move    x:(r7+$3b),x0           ; lastwet L
        move    x:(r7+$38),y1           ; fdbk
        mac     x0,y1,a
        move    a,x:(r7+$3d)
        move    x:(r7+$34),a            ; dry R
        asr     #$1,a,a
        move    x:(r7+$3c),x0           ; lastwet R
        move    x:(r7+$38),y1
        mac     x0,y1,a
        move    a,x:(r7+$3e)

; ---- the oscillator, ONCE for both channels ------------------------------
        move    x:(r7+$24),y0           ; step
        move    x:(r7+$1c),a            ; phase (shared with the ring mod --
        add     y0,a                    ;  the two modes are exclusive)
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$1c)
        bsr     lf_sin
        move    a,x:(r7+$2c)            ; sin
        move    x:(r7+$1c),a
        move    #>$400000,x0
        add     x0,a                    ; + a quarter turn
        move    a1,x0
        move    x0,a
        bsr     lf_sin
        move    a,x:(r7+$2d)            ; cos

; ---- the four Hilbert chains ---------------------------------------------
; POINTER-WALKED, not displacement-addressed. Each section is 12 words where
; BodeShift's is 21, and the difference is PARALLEL MOVES: an ALU op can
; carry a memory move in the same word, but only with (rn) addressing --
; never with r7+displacement. That is the whole reason BodeShift's sections
; cost what they do.
;
; The state is laid out y[n-2], y[n-1], x[n-2], x[n-1] so that BOTH the read
; walk and the write walk are monotonic: r1 reads ascending, r2 writes
; ascending one step behind, and no value is overwritten before its last
; use. The old order could not do this -- y[n-1] had to be written before
; x[n-2] was read.
;
; ONE setup pair covers all four chains: they sit at $40/$50/$60/$70
; contiguously and run in that order, so the pointers walk $40 to $7f once
; per sample and land exactly at the end. ⚠️ Anything inserted between the
; chains must therefore leave r1 and r2 alone.
; $40 is past lua's -64..63 displacement: `lua (r7+$40)` assembled to
; r7-$40, so until the port to this tree all four chains walked the 64
; words BELOW this instance's block (AGENTS.md). n1 = $40, set before the loop.
        move    r7,r1
        move    (r1)+n1
        move    r1,r2

        move    x:(r7+$3d),x1          ; chain A-L input
; ---- chain A-L section 0: allpass, c = 0.6923877778065 ----
        move    #>$58a02a,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain A-L section 1: allpass, c = 0.9360654322959 ----
        move    #>$77d0fe,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain A-L section 2: allpass, c = 0.9882295226860 ----
        move    #>$7e7e4e,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain A-L section 3: allpass, c = 0.9987488452737 ----
        move    #>$7fd701,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; I is chain A's output delayed one sample
        move    x:(r7+$39),b            ; I_L = aPrev L
        move    x1,x:(r7+$39)
        move    b,x:(r7+$2e)
        move    x:(r7+$3d),x1          ; chain B-L input
; ---- chain B-L section 0: allpass, c = 0.4021921162426 ----
        move    #>$337b08,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain B-L section 1: allpass, c = 0.8561710882420 ----
        move    #>$6d9704,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain B-L section 2: allpass, c = 0.9722909545651 ----
        move    #>$7c7408,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain B-L section 3: allpass, c = 0.9952884791278 ----
        move    #>$7f659d,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
        move    x1,x:(r7+$2f)           ; Q_L

        move    x:(r7+$3e),x1          ; chain A-R input
; ---- chain A-R section 0: allpass, c = 0.6923877778065 ----
        move    #>$58a02a,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain A-R section 1: allpass, c = 0.9360654322959 ----
        move    #>$77d0fe,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain A-R section 2: allpass, c = 0.9882295226860 ----
        move    #>$7e7e4e,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain A-R section 3: allpass, c = 0.9987488452737 ----
        move    #>$7fd701,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
        move    x:(r7+$3a),b            ; I_R = aPrev R
        move    x1,x:(r7+$3a)
        move    b,x:(r7+$30)
        move    x:(r7+$3e),x1          ; chain B-R input
; ---- chain B-R section 0: allpass, c = 0.4021921162426 ----
        move    #>$337b08,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain B-R section 1: allpass, c = 0.8561710882420 ----
        move    #>$6d9704,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain B-R section 2: allpass, c = 0.9722909545651 ----
        move    #>$7c7408,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
; ---- chain B-R section 3: allpass, c = 0.9952884791278 ----
        move    #>$7f659d,y1
        move    x1,x0
        mpy     x0,y1,a   x:(r1)+,x0    ; a = c*in       ; x0 = y[n-2]
        mac     x0,y1,a   x:(r1)+,x0    ; += c*y[n-2]    ; x0 = y[n-1]
        move    x0,x:(r2)+              ; y[n-2] <- y[n-1]
        move    x:(r1)+,x0              ; x0 = x[n-2]
        sub     x0,a      x:(r1)+,x0    ; a = y[n]       ; x0 = x[n-1]
        move    a,x:(r2)+               ; y[n-1] <- y[n]
        move    x0,x:(r2)+              ; x[n-2] <- x[n-1]
        move    x1,x:(r2)+              ; x[n-1] <- in
        move    a,x1
        move    x1,x:(r7+$31)           ; Q_R

; ---- the sidebands: wet = 2*(I*cos + s*(Q*sin)) --------------------------
; s is a per-block SIGN, +1 for UP and -1 for DOWN, so the direction costs
; no branch in the loop. Both channels share it: WIDE, which is where the
; two signs would differ, was dropped by design.
        move    x:(r7+$2e),x0           ; I_L
        move    x:(r7+$2d),y1           ; cos
        mpy     x0,y1,a
        move    a,x:(r7+$35)            ; park I*cos
        move    x:(r7+$2f),x0           ; Q_L
        move    x:(r7+$2c),y1           ; sin
        mpy     x0,y1,a
        move    a,x0
        move    x:(r7+$37),y1           ; s
        mpy     x0,y1,a
        move    x:(r7+$35),b
        add     b,a
        asl     #$1,a,a                 ; the x2 undoing the input halving
        move    a,x:(r7+$3b)            ; lastwet L, the feedback tap
        move    a,x:(r7+$35)            ; v L

        move    x:(r7+$30),x0           ; I_R
        move    x:(r7+$2d),y1
        mpy     x0,y1,a
        move    a,x:(r7+$36)
        move    x:(r7+$31),x0           ; Q_R
        move    x:(r7+$2c),y1
        mpy     x0,y1,a
        move    a,x0
        move    x:(r7+$37),y1
        mpy     x0,y1,a
        move    x:(r7+$36),b
        add     b,a
        asl     #$1,a,a
        move    a,x:(r7+$3c)            ; lastwet R
        move    a,x:(r7+$36)            ; v R
lf_noshift:
; MODEFORK_END

; ---- LPF: walk c0 toward its target, once per sample ---------------------
; The shelf's OTHER two coefficients are constants -- GN is fixed, so c1 and
; c2 never move and only c0 tracks the knob. Snapping it stepped the allpass
; output and clicked on every knob movement, which is what stock's smoother
; exists to prevent. Stock interpolates all three into absolute Y and streams
; them; we interpolate the one that moves, in r7, for six instructions a
; sample shared by both channels.
;
;   c += (target - c) / 256          ~5.8 ms time constant at 44.1k
;
; The shift truncates, so c stalls within 2^-16 of target instead of reaching
; it exactly. That is 1.5e-5 on a filter coefficient: inaudible, and stalling
; is the benign failure. A `mpy` by a smoothing constant would close the gap
; and cost a coefficient word to no audible end.
;
; ⚠️ HERE, after MODEFORK_END, deliberately: it must run in every mode, and
; inside the fork cycle_count.py would price it against one alternative only.
; a and b are both free at this point; b is live inside the shelf itself,
; which is why this cannot sit next to the code that uses it.
; Boot garbage in $3f is a legal coefficient (any 24-bit word is |c| <= 1, so
; the allpass stays stable) and it walks to target within a few ms of the
; first block. Consistent with the rest of the module's stance on r7 garbage.
        move    x:(r7+$1d),a            ; target c0, computed per block
        move    x:(r7+$3f),x0           ; c, the value actually in use
        sub     x0,a
        asr     #$8,a,a
        add     x0,a
        move    a,x:(r7+$3f)

; ---- the MODE duck, per sample: e moves one step toward its target -------
; Floored at 0 by tmi, capped near 1 by the store's limiter.
        move    x:(r7+$11),a            ; e
        move    x:(r7+$13),x0           ; the step, signed
        add     x0,a
        move    #>$0,x0
        tmi     x0,a
        move    a,x:(r7+$11)
        move    x:(r7+$11),x0           ; e as stored
        move    x:(r7+$20),y1           ; m
        mpy     x0,y1,b                 ; m*e
        move    x:(r7+$20),a
        sub     b,a                     ; m*(1-e): exactly m at e = 0
        move    a,x:(r7+$14)

; ---- MIX: crossfade the MODULATOR against the dry, HERE ------------------
; MIX is the modulator's depth, NOT a global wet/dry -- it sits between the
; ring/shift stage and the reduction stage, so SRR and BRR run on the result
; UNCONDITIONALLY and stay live at MIX=0. That is how stock LO-FI works: AMD
; crossfades the ring mod while SRR and BRR are always in circuit.
;   out = dry + m*(v - dry), the halve/double straddle keeping the difference
;   inside the accumulator when v and dry have opposite signs.
; ⚠️ There is therefore NO single-knob bypass. A passthrough is MIX 0 AND
; SRR 0 AND BRR 0 -- still the default state, so a freshly selected LOFI2 is
; transparent, but the null test needs all three at zero.
        move    x:(r7+$35),a            ; v L
        move    x:(r7+$33),b            ; dry L
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$14),y1           ; m*(1-e)
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$35)

        move    x:(r7+$36),a            ; v R
        move    x:(r7+$34),b            ; dry R
        sub     b,a
        asr     #$1,a,a
        move    a,x0
        move    x:(r7+$14),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        add     b,a
        move    a,x:(r7+$36)

; ---- SRR: advance the phase, latch the MODULATED pair on the wrap --------
        move    x:(r7+$1b),a            ; accumulator
        move    #>$10,x0                ; stock's fixed increment
        add     x0,a
        move    x:(r7+$25),x0           ; threshold
        cmp     x0,a
        blt     lf_held
        sub     x0,a                    ; crossed -- wrap by one threshold
        move    x:(r7+$35),x1           ; fresh: latch v, not the dry
        move    x1,x:(r7+$19)
        move    x:(r7+$36),x1
        move    x1,x:(r7+$1a)
lf_held:
        move    a,x:(r7+$1b)

; ---- L: quantise the held sample and write it out ------------------------
; out = dry + m*(wet - dry). The halve/double straddle keeps the difference
; inside the accumulator when wet and dry have opposite signs.
        move    x:(r7+$19),x0           ; held L
        move    x:(r7+$28),y1
        mpysu   x0,y1,a                 ; low half:  signed x unsigned
        move    x:(r7+$29),y1
        dmac    ss x0,y1,a              ; high half, accumulated shifted
        rnd     a                       ; ROUND TO NEAREST -- stock rounds;
        move    a,x1                    ; a truncating mask biases toward zero
        move    x:(r7+$2a),y1
        move    x:(r7+$2b),y0
        mpysu   x1,y1,b
        dmac    ss x1,y0,b              ; back up by 1/s
; 14 Sep 2026: #$19 -> #$18. The table at X:0x7400 is T[i] = -2^(-i/1024), so
; s = 2^(-frac/1024 - shift) and the backward read gives 2^(-(1023-frac)/1024)
; * 2^(shift-23). Their product is 2^(-1023/1024 - 23), i.e. 2^-24 to within
; 0.07%, while the double-precision chain's restoring shift of #$17 supplies
; only 2^23. Stock's quantiser therefore carries a structural x0.5, which
; stock's chain makes up elsewhere (the doubled coefficient half at Y:0x20a,
; exactly 2x the unit half at Y:0x212, feeds the filter at func_001d19 that
; writes the buffer this quantiser then crushes in place). LOFI2 has no such
; filter, so it supplies the x2 itself, here. #$18 measures +1.00135, flat
; through BRR ~64 and tracking stock's curve above it.
;
; The earlier "overflow at 127" reading was wrong: stock itself measures
; 0.447 at knob 127 for a 0.5 input, and 1.7875 was simply 4x that. Nothing
; overflows in the sweep. The one real overflow is the `neg` on the exact
; -1.0 at the table's first entry, handled by the limited stores above.
        asl     #$18,b,b                ; stock stores off #$17; ours off #$18

; ---- L: the shelf, LAST in the chain -------------------------------------
; func_000cb9 transcribed. Per sample, per channel:
;   b[n] = c0*b[n-1] + (in[n-1] - c0*in[n])/2      a one-pole allpass
;   out  = 16 * ( c1*in[n]/2 + c2*b[n] )
; The `asr` on the allpass sum, the `asr` on the direct term and the closing
; `asl #$4` are all stock's and are not a scaling of ours. What is NOT ported
; is stock's frame plumbing: it walks a copied frame with n0=2 and m0=$3f off
; n6, where we are already per-sample on the host's buffer, so the difference
; equation comes across and the pointer setup does not. Same call as the
; quantiser port.
; State is $80..$83 -- above the short-form line, so these are two-word
; moves, accepted because everything below $40 is spoken for. $00..$83 is
; usable and only $84..$8a is host-owned across calls (CHIP.md, bisected;
; the blanket "$84+ hangs" was retracted 30 Aug 2026).
; Boot garbage in the state is self-correcting: c0 < 1, so any legal word
; decays. No init needed.
        move    b1,x1                   ; in[n], the BRR output
        move    x:(r7+$3f),y1           ; c0, smoothed
        move    x1,x0
        mpy     -x0,y1,b                ; -c0*in[n]
        move    x:(r7+$81),x0           ; in[n-1]
        add     x0,b
        asr     b
        move    x:(r7+$80),x0           ; b[n-1]
        mac     x0,y1,b                 ; b[n]
        move    x1,x:(r7+$81)           ; in[n-1] <- in[n]
        move    b,x:(r7+$80)
        move    x:(r7+$1e),y1           ; c1
        move    x1,x0
        mpy     x0,y1,a
        asr     a                       ; c1*in[n]/2
        move    b,x0                    ; b[n]
        move    x:(r7+$1f),y1           ; c2
        mac     x0,y1,a
        asl     #$4,a,a                 ; stock's x16
        move    a,x:(r0)

; ---- R: the same ---------------------------------------------------------
        move    x:(r7+$1a),x0           ; held R
        move    x:(r7+$28),y1
        mpysu   x0,y1,a
        move    x:(r7+$29),y1
        dmac    ss x0,y1,a
        rnd     a
        move    a,x1
        move    x:(r7+$2a),y1
        move    x:(r7+$2b),y0
        mpysu   x1,y1,b
        dmac    ss x1,y0,b
        asl     #$18,b,b                ; matching L

; ---- R: the same shelf, its own two state words --------------------------
        move    b1,x1
        move    x:(r7+$3f),y1           ; c0, smoothed
        move    x1,x0
        mpy     -x0,y1,b
        move    x:(r7+$83),x0           ; in[n-1]
        add     x0,b
        asr     b
        move    x:(r7+$82),x0           ; b[n-1]
        mac     x0,y1,b
        move    x1,x:(r7+$83)
        move    b,x:(r7+$82)
        move    x:(r7+$1e),y1           ; c1
        move    x1,x0
        mpy     x0,y1,a
        asr     a
        move    b,x0
        move    x:(r7+$1f),y1           ; c2
        mac     x0,y1,a
        asl     #$4,a,a
        move    a,x:(r0+n0)

        move    #>$2,n0
        move    (r0)+n0
        move    #>$1,n0
lf_end:
        nop
        rts

; ---------------------------------------------------------------------------
; lf_sin -- sin(pi*p) for p in [-1,1), from BodeShift, which took it from
; WarpFold's carrier: the parabola 4p(1-|p|) refined by the standard
; 0.775/0.225 correction. Argument and result both in A.
; ---------------------------------------------------------------------------
lf_sin:
        move    a,x1
        abs     a
        move    #>$800000,x0
        add     x0,a                    ; |p| - 1
        neg     a                       ; t = 1 - |p|
        move    a,y1
        move    x1,x0
        mpy     x0,y1,a                 ; p*t
        asl     #$2,a,a                 ; y = 4p(1-|p|)
        move    a,x1
        move    a,x0
        abs     a
        move    a,y1                    ; |y|
        mpy     x0,y1,a                 ; y*|y|
        move    a,x0
        move    #>$1ccccd,y1            ; 0.225
        mpy     x0,y1,a
        move    x1,x0
        move    #>$633333,y1            ; 0.775
        mac     x0,y1,a
        rts

; ---------------------------------------------------------------------------
; RESOLVED: SHIFT gets its OWN pair of bases, not RING's. Opened 5 Sep 2026 --
; 60 Hz-4 kHz is well past where a shifter stays musical, BodeShift stopped at
; 1,000 Hz on purpose -- and settled by following the Bode 1630's own
; exponential scale of 2 Hz-2 kHz: LOW keeps the 2 Hz floor, HIGH starts at
; 31.25 Hz so six octaves lands on exactly 2,000 Hz. Both base constants are
; selected in the FREQ block above off the shift flag at r7+$32.
;
; STILL AN EAR DECISION, deferred: whether six exponential octaves feels right
; under the knob in either mode, and whether the SHIFT pair wants moving again
; once it has had real playing time.
; ---------------------------------------------------------------------------
