| REC MATRIX, proof of concept: SRC3 = 10 (MTRX) records a sum of sources
| chosen per recorder, through stock's own SRC3 slot.
|
| Hooked at the recorder's SRC3 select inside the write path
| 0x400068e4(track, page, start, end) (docs/firmware/RECORDER.md section 2):
| stock sign-extends the SRC3 byte into d1, sends 0..7 (T1..T8) to the
| read-back block and 8..9 (MAIN, CUE) to 0x80005e60, then meets at
| 0x40007648 with the SRC3 pointer in d5. For 10 this stub fills one
| segment of a per-recorder block and points d5 at it; everything after
| (stock's SRC3 gain and FIN/FOUT ramp, INAB/INCD, the old-content path,
| stage 2's saturating sum, the pack) runs unchanged.
|
| Mixing rules (stock's own, docs: the INAB table at 0x80004808):
|   AB set           -> A left, B right, unity (the pair's A/B bits ignored)
|   A and B, no AB   -> 0.5 * (A + B) to both sides (stock's A+B entry)
|   A or B alone     -> that input to both sides, unity
|   the same for CD; T1..T8, MAIN, CUE -> stereo, unity
| The sum runs in 24-bit integers (each long's top 24 bits; the low byte,
| which carries junk on one core's read-back half, is dropped), so 16
| sources have headroom; the result saturates to 24 bits once, at the end.
|
| Mask bits: 0 A, 1 B, 2 C, 3 D, 4 AB, 5 CD, 6..13 T1..T8, 14 MAIN, 15 CUE.
| Proof of concept: the mask table is a constant (rmx_mask below).

        .equ    SEL_CONT,   0x400075E4      | stock: blts 0x40007600 (after cmpl d1,d4)
        .equ    MIX_CONT,   0x40007648      | stock: both pointer branches meet here
        .equ    RDBK_BASE,  0x80003190      | read-back block, half 0, T1
        .equ    RDBK_BANK,  0x800000E4      | the half the recorder and NEIGHBOR read
        .equ    MAINCUE,    0x80005E60      | MAIN at +0x00, CUE at +0x80
        .equ    SRC_MTRX,   10

        .text

| Entry: the jmp written over stock's `mvsb d1,d1; moveq #7,d4; cmpl d1,d4`.
| Registers live into 0x40007648: a2 (AB pointer), d6 (CD pointer), fp;
| d5 is the output. d0-d4, d7, a0, a1, a3-a5 are rewritten there before use.
        .global rmx_select
rmx_select:
        mvs.b   %d1,%d1
        moveq   #SRC_MTRX,%d4
        cmp.l   %d4,%d1
        beq.s   .Lmtrx
        moveq   #7,%d4                      | displaced, replayed
        cmp.l   %d1,%d4                     | sets the flags stock's blts reads
        jmp     SEL_CONT

.Lmtrx:
        move.l  136(%sp),%d0                | recorder 0..7 (the routine's first argument)
        lea     rmx_mask,%a1
        mvz.w   (%a1,%d0.l*2),%d3           | d3 = this recorder's mask
        lsl.l   #7,%d0
        lea     rmx_buf,%a4
        add.l   %d0,%a4                     | a4 = this recorder's 16-sample block
        move.l  144(%sp),%d4                | start sample
        lsl.l   #3,%d4                      | d4 = start * 8 (one stereo pair)
        add.l   %d4,%a4                     | a4 = this segment
        move.l  48(%sp),%d7                 | d7 = sample count (end - start)
        tst.l   %d7
        ble.w   .Ldone

        move.l  %a4,%a1                     | clear the segment
        move.l  %d7,%d0
.Lclr:  clr.l   (%a1)+
        clr.l   (%a1)+
        subq.l  #1,%d0
        bgt.s   .Lclr

        btst    #4,%d3                      | a stereo pair overrides its mono bits
        beq.s   1f
        and.l   #0xfffffffc,%d3
1:      btst    #5,%d3
        beq.s   2f
        and.l   #0xfffffff3,%d3
2:
| ---- A / B: a2 = page + 0x80 + start*8, A at +0, B at +4 --------------------
        move.l  %a2,%a3
        btst    #4,%d3
        beq.s   .Lab_mono
        bsr.w   rmx_add_stereo
        bra.s   .Lcd
.Lab_mono:
        move.l  %d3,%d0
        and.l   #3,%d0
        beq.s   .Lcd
        cmp.l   #3,%d0
        bne.s   .Lab_one
        bsr.w   rmx_add_fold
        bra.s   .Lcd
.Lab_one:
        cmp.l   #1,%d0
        beq.s   .Lab_a
        addq.l  #4,%a3                      | B alone: the second long
.Lab_a: bsr.w   rmx_add_mono

| ---- C / D: d6 = page + start*8, C at +0, D at +4 ---------------------------
.Lcd:   move.l  %d6,%a3
        btst    #5,%d3
        beq.s   .Lcd_mono
        bsr.w   rmx_add_stereo
        bra.s   .Ltracks
.Lcd_mono:
        move.l  %d3,%d0
        lsr.l   #2,%d0
        and.l   #3,%d0
        beq.s   .Ltracks
        cmp.l   #3,%d0
        bne.s   .Lcd_one
        bsr.w   rmx_add_fold
        bra.s   .Ltracks
.Lcd_one:
        cmp.l   #1,%d0
        beq.s   .Lcd_c
        addq.l  #4,%a3
.Lcd_c: bsr.w   rmx_add_mono

| ---- T1..T8: 0x80003190 + bank*0x400 + k*0x80 + start*8 (stock's formula) ---
.Ltracks:
        move.l  RDBK_BANK,%d0
        moveq   #10,%d1
        lsl.l   %d1,%d0
        add.l   #RDBK_BASE,%d0
        add.l   %d4,%d0
        move.l  %d0,%a5
        moveq   #6,%d2
.Ltr:   btst    %d2,%d3
        beq.s   3f
        move.l  %a5,%a3
        bsr.w   rmx_add_stereo
3:      lea     0x80(%a5),%a5
        addq.l  #1,%d2
        moveq   #14,%d0
        cmp.l   %d0,%d2
        blt.s   .Ltr

| ---- MAIN, CUE --------------------------------------------------------------
        btst    #14,%d3
        beq.s   4f
        move.l  #MAINCUE,%d0
        add.l   %d4,%d0
        move.l  %d0,%a3
        bsr.w   rmx_add_stereo
4:      btst    #15,%d3
        beq.s   5f
        move.l  #MAINCUE+0x80,%d0
        add.l   %d4,%d0
        move.l  %d0,%a3
        bsr.w   rmx_add_stereo
5:
| ---- saturate to 24 bits and put each back in the top of its long ----------
        move.l  %a4,%a1
        move.l  %d7,%d0
        add.l   %d0,%d0                     | two longs a sample
.Lsat:  move.l  (%a1),%d1
        cmp.l   #0x007fffff,%d1
        ble.s   6f
        move.l  #0x007fffff,%d1
        bra.s   7f
6:      cmp.l   #0xff800000,%d1
        bge.s   7f
        move.l  #0xff800000,%d1
7:      lsl.l   #8,%d1
        move.l  %d1,(%a1)+
        subq.l  #1,%d0
        bgt.s   .Lsat

.Ldone: move.l  %a4,%d5                     | the SRC3 pointer, as stock leaves it
        jmp     MIX_CONT

| Helpers: a3 = source, a4 = segment, d7 = count. Clobber d0, d1, a1, a3.
rmx_add_stereo:
        move.l  %a4,%a1
        move.l  %d7,%d0
1:      move.l  (%a3)+,%d1
        asr.l   #8,%d1
        add.l   %d1,(%a1)+
        move.l  (%a3)+,%d1
        asr.l   #8,%d1
        add.l   %d1,(%a1)+
        subq.l  #1,%d0
        bgt.s   1b
        rts

| One channel of a pair (a3 at its long, stride 8) to both sides.
rmx_add_mono:
        move.l  %a4,%a1
        move.l  %d7,%d0
1:      move.l  (%a3),%d1
        asr.l   #8,%d1
        add.l   %d1,(%a1)+
        add.l   %d1,(%a1)+
        addq.l  #8,%a3
        subq.l  #1,%d0
        bgt.s   1b
        rts

| Both channels of a pair folded to mono at 0.5 each, to both sides.
rmx_add_fold:
        move.l  %d2,-(%sp)
        move.l  %a4,%a1
        move.l  %d7,%d0
1:      move.l  (%a3)+,%d1
        asr.l   #8,%d1
        move.l  (%a3)+,%d2
        asr.l   #8,%d2
        add.l   %d2,%d1
        asr.l   #1,%d1
        add.l   %d1,(%a1)+
        add.l   %d1,(%a1)+
        subq.l  #1,%d0
        bgt.s   1b
        move.l  (%sp)+,%d2
        rts

| 0x4002fc00, a "jsr" detour: RECORDING SETUP 1's push of the stock SRC3
| formatter 0x4002f15c (`move.l d4,(sp); pea pc(0x4002f15c)`), replayed with
| src3_fmt pushed instead. d0 is dead at the site (rewritten at 0x4002fc16).
        .global src3_screen
src3_screen:
        move.l  (%sp)+,%d0                  | the return address
        move.l  %d4,(%sp)                   | displaced
        pea     src3_fmt                    | in place of the stock formatter
        move.l  %d0,-(%sp)
        rts

| fmt(buf, value): 11 -> "MTRX"; else the stock formatter (-, T1..T8, MAIN,
| CUE; stock prints CUE for anything above 10).
src3_fmt:
        moveq   #SRC_MTRX+1,%d0             | the stored value (the runtime one is 10)
        cmp.l   8(%sp),%d0
        bne.s   .sf_stock
        lea     mtrx_label,%a0
        move.l  %a0,8(%sp)
        jmp     (0x40013a08).l              | sprintf(buf, "MTRX")
.sf_stock:
        jmp     (0x4002f15c).l

mtrx_label:
        .asciz  "MTRX"

| Proof-of-concept matrix: recorder 2 (index 1) = A + B (folded) + T1.
        .balign 4
        .global rmx_mask
rmx_mask:
        .word   0x0000, 0x0043, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000

        .bss
        .balign 4
        .global rmx_buf
rmx_buf:
        .space  8 * 16 * 8                  | 8 recorders x 16 samples x L,R
