| USB IN (test) -- one more host-port transfer per frame: 128 halfwords to
| core 0 at $6320 (the idle bank + $320, where the DSP's rx_inject.asm reads
| them next frame).
|
| Hooked at state 7 of the frame transfer machine (0x40004bc0, `moveq #1,d1 ;
| move.b d1,0xfc04801d` -- 8 bytes, the frame interrupt's unmask). Reached
| from the machine's IRQ handler 0x40004840, which saved d0-d1/a0-a1 and
| returns through 0x40004bc8 (movem restore, rte) after this rts.
|
|   first visit (flag clear): set the flag, fill the test pattern, program
|     eDMA ch 0 exactly as state 4/5 do (NBYTES 64, CITER/BITER 0x8004 =
|     4 x 64 B = 128 halfwords), chip select core 0, command $6320, count
|     127, host vector 0x88, start. The state stays 7.
|   second visit (this DMA's completion): clear the flag, run stock state 7.
|
| Test pattern, DSP order (slot-interleaved 16 x 4), one 24-bit value per
| sample v = slot<<20 | (frame & 0xff)<<12 | s<<8 | 0xa5, sent as two
| halfwords: v>>8, v & 0xff.
|
| All data access through the uncached alias (+0x08000000): the eDMA does
| not see the data cache (docs/remixer/PLACEMENT.md). Position-independent.

        .text
cave:   lea     st(%pc),%a0
        adda.l  #0x08000000,%a0         | a0 = state, uncached
        tst.b   (%a0)
        bne.w   second
        move.b  #1,(%a0)

        lea     -12(%sp),%sp
        movem.l %d2-%d4,(%sp)
        move.l  4(%a0),%d2
        addq.l  #1,%d2
        move.l  %d2,4(%a0)              | frame counter
        andi.l  #0xff,%d2
        lsl.l   #8,%d2
        lsl.l   #4,%d2                  | d2 = (f & 0xff) << 12
        lea     16(%a0),%a1             | a1 = buffer, uncached
        moveq   #0,%d0                  | s
sloop:  moveq   #0,%d1                  | slot
kloop:  move.l  %d1,%d3
        lsl.l   #8,%d3
        lsl.l   #8,%d3
        lsl.l   #4,%d3                  | slot << 20
        or.l    %d2,%d3
        move.l  %d0,%d4
        lsl.l   #8,%d4
        or.l    %d4,%d3
        ori.l   #0xa5,%d3               | v
        move.l  %d3,%d4
        lsr.l   #8,%d4
        move.w  %d4,(%a1)+              | v >> 8
        andi.l  #0xff,%d3
        move.w  %d3,(%a1)+              | v & 0xff
        addq.l  #1,%d1
        moveq   #4,%d4
        cmp.l   %d4,%d1
        blt.s   kloop
        addq.l  #1,%d0
        moveq   #16,%d4
        cmp.l   %d4,%d0
        blt.s   sloop
        movem.l (%sp),%d2-%d4
        lea     12(%sp),%sp

        clr.b   %d0
        move.b  %d0,0xfc0a400c          | chip select: core 0
        moveq   #64,%d1
        move.l  %d1,0xfc045008          | NBYTES
        lea     16(%a0),%a1
        move.l  %a1,0xfc045000          | SADDR = buffer (uncached alias)
        move.w  #0x81,%d0
        move.w  %d0,0x20000000
        move.w  #0x6320,%d1
        move.w  %d1,0x2000001c          | destination
        move.w  #127,%d0
        move.w  %d0,0x2000001c          | count - 1
        move.w  #0x88,%d1
        move.w  %d1,0x20000004          | host vector
        move.w  #0x8004,%d0
        move.w  %d0,0xfc045014          | CITER
        move.w  %d0,0xfc04501c          | BITER
        clr.b   %d1
        move.b  %d1,0xfc04401e          | start ch 0
        rts

second: clr.b   (%a0)
        moveq   #1,%d1                  | stock state 7, replayed
        move.b  %d1,0xfc04801d
        rts

        .balign 4
st:     .long   0, 0, 0, 0              | +0 flag byte, +4 frame counter
buf:    .space  256
