; ---------------------------------------------------------------------------
; USB IN (test): overwrite core 0's current RX block with 64 words the
; ColdFire sent into the working bank at +$320 the frame before.
;
; Placed at P:$aa8 (SPATIALIZER's first words, payload A only; id 5's
; dispatch is repointed to NONE by the same module). Reached by a
; `jsr >$aa8` that replaces the dispatcher's `move r2,x:>$204` at P:$88,
; which this routine replays first.
;
; At P:$88 (static read, docs: usb-audio-main-cue-plan 3b/4a):
;   x:$202  = the RX block just stored at P:$86 (64 words, slot-interleaved
;             16 x 4: slots 0/1 = C/D, 2/3 = A/B)
;   r6      = working bank base ($2000 or $4000); the ColdFire's command
;             $6320 lands at +$320 of the OTHER bank, i.e. this one next frame
;   live    : r2 (stored here), r4 r5 r6 r7 b  -- NOT touched
;   free    : a, x1, r0, r1 (each reassigned by stock before its next read:
;             x1 first at P:$c8, r0 at P:$9b, r1 at P:$a8, a at P:$b2);
;             m0/m1 linear (stock walks (r0)+ / (r1)+ right after)
;
; Wire format, per sample: two host words, 16 bits each, right-justified
;   w0 = sample[23:8], w1 = sample[7:0]
; A host word's top byte arrives NONZERO under the port (0x03 seen, 26 Sep
; 2026); stock never sees it because it shifts or masks every host word.
; Both words are masked here.
;
; Every instruction form here has a stock precedent in payload A (AGENTS.md:
; the port cannot prove a form the chip never ran). `asl #8,a,a` (P:$921)
; `and #>$ff,a` (P:$b3), `move a1,x1` and `add x1,a` stand in for lsl/or,
; which have none. The store
; is `move a1,...`, which is not limited, so a1 bit 23 with a2 = 0 is safe.
; ---------------------------------------------------------------------------

inject:
        move    r2,x:>$204              ; the displaced instruction
        move    r6,a
        add     #>$320,a
        move    a,r0                    ; r0 = working bank + $320
        move    x:>$202,r1              ; r1 = current RX block
        do      #64,inj_end
        move    x:(r0)+,a               ; hi word; its top byte is not zero on the port
        asl     #8,a,a                  ; a1 = sample[23:8] << 8 (the top byte leaves a1)
        move    a1,x1
        move    x:(r0)+,a               ; lo word
        and     #>$ff,a                 ; a1 = sample[7:0]
        add     x1,a                    ; a1 = sample (low byte of x1 is zero: add = or)
        move    a1,x:(r1)+              ; a1, not a: no limiting whatever a2 holds
inj_end:
        rts
