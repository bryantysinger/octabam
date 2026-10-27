| FRAME PROFILE -- where the frame interrupt's time goes, by section, on DMA
| timer 3 (DTCN3, 132 MHz), published every 0.5 s for tools/hw/task_meter.py
| (USB vendor request 0xc0/0x57 block 5).
|
| Seams (each a jsr in place of one whole stock instruction, replayed in the
| stub; the frame interrupt runs at level 5):
|   S0 0x4000ab08  jsr 0x4001c9b0      the frame's first call: the frame starts
|   S1 0x4000d0de  jsr 0x40004db8      section 0 ends: head (host-command handshake, sequencer)
|   S2 0x4000d0ea  movel 0x80004800,d0 section 1 ends: the two calls 0x40004db8 / 0x40004bd4
|   S3 0x4000d31a  lea 0x46c7ff42,a2   section 2 ends: track prep up to the recorder dispatcher
|   S4 0x4000d3d4  lea 0x400d61d0,a3   section 3 ends: the per-track recorder dispatcher (0x400068e4, 0x40005ff0)
|   S5 0x4000d562  lea 0x800000f0,a1   section 4 ends: the packer and the machine renderers (the voices)
|   S6 0x4000d938  tstl 0x46104d04     section 5 ends: mix, MIDI; the frame's accounting closes
| The rest (S6 to the epilogue, the entry prologue before S0) is LOAD METER's
| total less the sections, done on the host.
| Each section's time leaves out the level-6 eDMA handler's runs inside it
| (0x40004840 entry, 0x40004bc8 its one exit, as CF METER times it), which
| are summed on their own. The busy-waits are timed whole (wall time, a
| level-6 run inside one included): the host-port command acknowledges
| (0x4000ab26, 0x4000a90c, polling 0x20000004) and the renderer's eDMA done
| polls (0x400035a8 channel 3, 0x40003780 channel 5).
| A frame that takes the path that skips S1..S6 (0x4000ab12) is counted as alt.
| SPDX-License-Identifier: MIT

        .equ    DTCN3,  0xfc07c00c
        .equ    HCR,    0x20000004
        .equ    WIN,    66000000                | 0.5 s at 132 MHz
        .equ    NSEC,   6

        .text
| ---- the seams: d0-d2/a0 saved, interrupts held at 7 while the shared words move
.macro  FP_ENTER
        lea     -16(%sp),%sp
        movem.l %d0-%d2/%a0,(%sp)
        move.w  %sr,%d1
        move.w  #0x2700,%sr
        move.l  DTCN3,%d0
.endm
.macro  FP_LEAVE
        move.w  %d1,%sr
        movem.l (%sp),%d0-%d2/%a0
        lea     16(%sp),%sp
.endm
| d0 = now: the current section gets now - last - nested, the next one starts
.macro  FP_CLOSE next
        tst.b   fp_inframe
        beq.s   9f
        move.l  %d0,%d2
        sub.l   fp_last,%d0
        sub.l   fp_nest,%d0
        move.l  %d2,fp_last
        clr.l   fp_nest
        move.l  fp_cur,%d2
        lea     fp_acc,%a0
        add.l   %d0,(%a0,%d2.l*4)
        moveq   #\next,%d2
        move.l  %d2,fp_cur
9:
.endm

        .globl  fp_s0, fp_s1, fp_s2, fp_s3, fp_s4, fp_s5, fp_s6
fp_s0:
        FP_ENTER
        tst.b   fp_inframe
        beq.s   1f
        addq.l  #1,fp_alt                       | the last frame left by the other path
1:      move.l  %d0,fp_last
        clr.l   fp_nest
        clr.l   fp_cur
        moveq   #1,%d2
        move.b  %d2,fp_inframe
        FP_LEAVE
        jmp     0x4001c9b0                      | displaced: jsr 0x4001c9b0 (our caller's return stays)
fp_s1:
        FP_ENTER
        FP_CLOSE 1
        FP_LEAVE
        jmp     0x40004db8                      | displaced: jsr 0x40004db8
fp_s2:
        FP_ENTER
        FP_CLOSE 2
        FP_LEAVE
        move.l  0x80004800,%d0                  | displaced
        rts
fp_s3:
        FP_ENTER
        FP_CLOSE 3
        FP_LEAVE
        lea     0x46c7ff42,%a2                  | displaced
        rts
fp_s4:
        FP_ENTER
        FP_CLOSE 4
        FP_LEAVE
        lea     0x400d61d0,%a3                  | displaced
        rts
fp_s5:
        FP_ENTER
        FP_CLOSE 5
        FP_LEAVE
        lea     0x800000f0,%a1                  | displaced
        rts
fp_s6:
        FP_ENTER
        FP_CLOSE 5
        tst.b   fp_inframe
        beq     8f
        clr.b   fp_inframe
        addq.l  #1,fp_frames
        move.l  DTCN3,%d0
        move.l  %d0,%d2
        sub.l   fp_w0,%d0
        cmp.l   #WIN,%d0
        bcs     8f
        lea     fp_stats,%a0                    | publish: seq last
        move.l  %d0,4(%a0)                      | window
        move.l  %d2,fp_w0
        move.l  fp_frames,%d0
        move.l  %d0,8(%a0)
        move.l  fp_alt,%d0
        move.l  %d0,12(%a0)
        moveq   #0,%d2
2:      lea     fp_acc,%a0
        move.l  (%a0,%d2.l*4),%d0
        clr.l   (%a0,%d2.l*4)
        lea     fp_stats+16,%a0
        move.l  %d0,(%a0,%d2.l*4)
        addq.l  #1,%d2
        moveq   #NSEC,%d0
        cmp.l   %d2,%d0
        bne.s   2b
        lea     fp_stats,%a0
        move.l  fp_xin,%d0
        move.l  %d0,40(%a0)
        move.l  fp_xall,%d0
        move.l  %d0,44(%a0)
        move.l  fp_xcnt,%d0
        move.l  %d0,48(%a0)
        move.l  fp_shc,%d0
        move.l  %d0,52(%a0)
        move.l  fp_sd3,%d0
        move.l  %d0,56(%a0)
        move.l  fp_sd5,%d0
        move.l  %d0,60(%a0)
        moveq   #0,%d2                          | the USB timers (usbaudio.s usb_tm), taken and cleared
3:      lea     usb_tm,%a0
        move.l  (%a0,%d2.l*4),%d0
        clr.l   (%a0,%d2.l*4)
        lea     fp_stats+64,%a0
        move.l  %d0,(%a0,%d2.l*4)
        addq.l  #1,%d2
        moveq   #4,%d0
        cmp.l   %d2,%d0
        bne.s   3b
        lea     fp_stats,%a0
        clr.l   fp_frames
        clr.l   fp_alt
        clr.l   fp_xin
        clr.l   fp_xall
        clr.l   fp_xcnt
        clr.l   fp_shc
        clr.l   fp_sd3
        clr.l   fp_sd5
        addq.l  #1,(%a0)                        | the seq last: a reader sees a whole window
8:      FP_LEAVE
        tst.l   0x46104d04                      | displaced (its flags are the next beq's)
        rts

| ---- the busy-waits, displaced whole; d0 is the loop's scratch, stock
| reloads it after each (CF METER's m_hc1/m_hc2 pattern)
        .globl  fp_hc1, fp_hc2, fp_d3, fp_d5
fp_hc1:
        move.l  DTCN3,%d0
        move.l  %d0,fp_st0
1:      move.w  HCR,%d0
        tst.b   %d0
        blt.s   1b
        move.l  DTCN3,%d0
        sub.l   fp_st0,%d0
        add.l   %d0,fp_shc
        jmp     0x4000ab30
fp_hc2:
        move.l  DTCN3,%d0
        move.l  %d0,fp_st0
1:      move.w  HCR,%d0
        tst.b   %d0
        blt.s   1b
        move.l  DTCN3,%d0
        sub.l   fp_st0,%d0
        add.l   %d0,fp_shc
        jmp     0x4000a916
fp_d3:
        move.l  DTCN3,%d0
        move.l  %d0,fp_st0
1:      move.w  0xfc04507e,%d0
        tst.b   %d0
        bge.s   1b
        move.l  DTCN3,%d0
        sub.l   fp_st0,%d0
        add.l   %d0,fp_sd3
        jmp     0x400035b2
fp_d5:
        move.l  DTCN3,%d0
        move.l  %d0,fp_st0
1:      move.w  0xfc0450be,%d0
        tst.b   %d0
        bge.s   1b
        move.l  DTCN3,%d0
        sub.l   fp_st0,%d0
        add.l   %d0,fp_sd5
        jmp     0x4000378a

| ---- the level-6 eDMA handler: entry, and its one exit
        .globl  fp_x6, fp_x6x
fp_x6:
        lea     -16(%sp),%sp                    | displaced
        movem.l %d0-%d1/%a0-%a1,(%sp)           | displaced
        move.l  DTCN3,%d0
        move.l  %d0,fp_xt0
        jmp     0x40004848
fp_x6x:
        move.l  DTCN3,%d0
        sub.l   fp_xt0,%d0
        add.l   %d0,fp_xall
        addq.l  #1,fp_xcnt
        tst.b   fp_inframe
        beq.s   1f
        add.l   %d0,fp_xin
        add.l   %d0,fp_nest
1:      movem.l (%sp),%d0-%d1/%a0-%a1           | displaced
        lea     16(%sp),%sp                     | displaced
        rte                                     | displaced

        .data
        .balign 4
        .globl  fp_stats, FP_STATS
| seq, window, frames, alt, sec0..sec5, xfer_in_frame, xfer_all, xfer_count,
| spin_hostcmd, spin_dma3, spin_dma5, usb_out_shim, usb_producer, usb_in_frame,
| usb_in_build, 4 spare (timer 3 counts, sums over the window)
FP_STATS:
fp_stats: .space 96
fp_acc:   .space 4*NSEC
fp_last:  .long 0
fp_nest:  .long 0
fp_cur:   .long 0
fp_w0:    .long 0
fp_frames: .long 0
fp_alt:   .long 0
fp_xt0:   .long 0
fp_xin:   .long 0
fp_xall:  .long 0
fp_xcnt:  .long 0
fp_st0:   .long 0
fp_shc:   .long 0
fp_sd3:   .long 0
fp_sd5:   .long 0
fp_inframe: .byte 0
        .balign 4
