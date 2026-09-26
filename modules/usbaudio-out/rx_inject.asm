; ---------------------------------------------------------------------------
; USB AUDIO OUT, DSP side: while the host's stream is open, overwrite core
; 0's current RX block with the 64 words the ColdFire sent into the working
; bank at +$320 the frame before; while it is closed, leave the jacks.
;
; The same placement and hook as usbin-test's rx_inject.asm (P:$aa8,
; SPATIALIZER's first words on payload A; `jsr >$aa8` for P:$88's
; `move r2,x:>$204`, replayed first) and the same wire format:
;   per sample two host words, w0 = sample[23:8], w1 = sample[7:0];
;   the top byte of a host word is not zero, so both are masked.
; NEW: the stream flag, bit 8 of the first sample's low word (x:(r0+1)),
; which the loop masks off like the rest of that word's top bits.
;
; Every instruction form has a stock precedent in payload A:
;   move x:(r0+$nn),a  (P:$117, one-word displaced), and #>imm,a (38
;   sites), beq short (P:$3e0), and the loop's forms (usbin-test).
; Live at P:$88: r2 (stored here), r4 r5 r6 r7 b -- not touched. Free: a,
; x1, r0, r1 (stock reassigns each before its next read).
; ---------------------------------------------------------------------------

inject:
        move    r2,x:>$204              ; the displaced instruction
        move    r6,a
        add     #>$320,a
        move    a,r0                    ; r0 = working bank + $320
        move    x:(r0+1),a              ; first low word: the stream flag
        and     #>$100,a
        beq     inj_end                 ; stream closed: the jacks stay
        move    x:>$202,r1              ; r1 = current RX block
        do      #64,inj_end
        move    x:(r0)+,a               ; hi word; its top byte is not zero
        asl     #8,a,a                  ; a1 = sample[23:8] << 8
        move    a1,x1
        move    x:(r0)+,a               ; lo word (flag bit included)
        and     #>$ff,a                 ; a1 = sample[7:0]
        add     x1,a                    ; low byte of x1 is zero: add = or
        move    a1,x:(r1)+              ; a1, not a: no limiting
inj_end:
        rts
