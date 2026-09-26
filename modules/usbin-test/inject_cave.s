| USB IN (test) -- one more host-port transfer per frame: 128 halfwords to
| core 0 at $6320 (the idle bank + $320, where the DSP's rx_inject.asm reads
| them next frame).
|
| Hooked at state 7 of the frame transfer machine (0x40004bc0, `moveq #1,d1 ;
| move.b d1,0xfc04801d` -- 8 bytes, the frame interrupt's unmask). Reached
| from the machine's IRQ handler 0x40004840, which saved d0-d1/a0-a1 and
| returns through 0x40004bc8 (movem restore, rte) after this rts.
|
|   first visit (busy clear): set busy, generate 16 samples x 4 channels,
|     program eDMA ch 0 exactly as states 4/5 do (NBYTES 64, CITER/BITER
|     0x8004 = 4 x 64 B = 128 halfwords), chip select core 0, command $6320,
|     count 127, host vector 0x88, start. The state stays 7.
|   second visit (this DMA's completion): clear busy, run stock state 7.
|
| Test signal: four sines at -20 dBFS (0.1 FS), phase-continuous across
| frames, 32-bit phase accumulators, 256-entry table, no interpolation
| (spurs about -48 dBc). DSP slot order (16 samples x 4 slots):
|   slot 0 = input C  880 Hz     slot 2 = input A  440 Hz
|   slot 1 = input D 1100 Hz     slot 3 = input B  660 Hz
| (the firmware's GAIN CD / GAIN AB assignment, plan section 3b). Each 24-bit
| sample goes as two halfwords, v[23:8] and v[7:0].
|
| MEMORY. The buffer the eDMA reads is in this cave, cached-copyback SDRAM,
| and the eDMA does not see the data cache. Every data access to the state
| and buffer goes through the uncached alias (+0x08000000). On the first run
| the data-cache lines covering them at their CACHED address are pushed with
| `cpushl dc`, once, before any write: a line left dirty by anything earlier
| cannot later be evicted over the buffer, and nothing touches these
| addresses through the cached map afterwards. The stock image has no
| cpushl in code (every disassembled hit is inside a data table), so the unit
| is this instruction's first proof. The sine and increment tables are
| read-only and read through the cached map.

        .text
cave:   lea     st(%pc),%a0
        adda.l  #0x08000000,%a0         | a0 = state, uncached
        tst.b   1(%a0)                  | cache lines pushed yet?
        bne.s   ready
        lea     st(%pc),%a1             | cached address
        move.l  %a1,%d0
        andi.l  #-16,%d0
        movea.l %d0,%a1
        moveq   #19,%d0                 | 16 B lines over st..buf end (304 B)
flush:  cpushl  %dc,(%a1)
        lea     16(%a1),%a1
        subq.l  #1,%d0
        bne.s   flush
        move.b  #1,1(%a0)
ready:  tst.b   (%a0)
        bne.w   second
        move.b  #1,(%a0)                | busy

        lea     -24(%sp),%sp
        movem.l %d2-%d4/%a2-%a4,(%sp)
        lea     32(%a0),%a1             | buffer, uncached
        lea     sine(%pc),%a4
        moveq   #16,%d0                 | samples
sloop:  lea     16(%a0),%a2             | phases, uncached
        lea     incs(%pc),%a3
        moveq   #4,%d1                  | slots
kloop:  move.l  (%a2),%d2
        add.l   (%a3)+,%d2
        move.l  %d2,(%a2)+              | phase += inc
        moveq   #24,%d4
        lsr.l   %d4,%d2                 | table index
        move.l  0(%a4,%d2.l*4),%d3      | v, sign-extended 24-bit
        move.l  %d3,%d4
        asr.l   #8,%d4
        move.w  %d4,(%a1)+              | v[23:8]
        andi.l  #0xff,%d3
        move.w  %d3,(%a1)+              | v[7:0]
        subq.l  #1,%d1
        bne.s   kloop
        subq.l  #1,%d0
        bne.s   sloop
        movem.l (%sp),%d2-%d4/%a2-%a4
        lea     24(%sp),%sp

        clr.b   %d0
        move.b  %d0,0xfc0a400c          | chip select: core 0
        moveq   #64,%d1
        move.l  %d1,0xfc045008          | NBYTES
        lea     32(%a0),%a1
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
incs:   .long   85704563, 107130704, 42852281, 64278422   | 880 1100 440 660 Hz: round(f / 44100 * 2^32)
sine:                                   | round(0.1 * 2^23 * sin(2 pi i / 256))
        .long   0, 20587, 41161, 61710, 82223, 102686, 123086, 143413
        .long   163654, 183795, 203827, 223735, 243508, 263135, 282604, 301902
        .long   321018, 339941, 358659, 377161, 395436, 413473, 431261, 448789
        .long   466046, 483023, 499709, 516094, 532168, 547921, 563345, 578429
        .long   593164, 607543, 621555, 635193, 648448, 661313, 673779, 685840
        .long   697487, 708715, 719515, 729882, 739809, 749291, 758321, 766895
        .long   775007, 782651, 789825, 796522, 802740, 808474, 813721, 818478
        .long   822743, 826511, 829782, 832552, 834822, 836588, 837851, 838608
        .long   838861, 838608, 837851, 836588, 834822, 832552, 829782, 826511
        .long   822743, 818478, 813721, 808474, 802740, 796522, 789825, 782651
        .long   775007, 766895, 758321, 749291, 739809, 729882, 719515, 708715
        .long   697487, 685840, 673779, 661313, 648448, 635193, 621555, 607543
        .long   593164, 578429, 563345, 547921, 532168, 516094, 499709, 483023
        .long   466046, 448789, 431261, 413473, 395436, 377161, 358659, 339941
        .long   321018, 301902, 282604, 263135, 243508, 223735, 203827, 183795
        .long   163654, 143413, 123086, 102686, 82223, 61710, 41161, 20587
        .long   0, -20587, -41161, -61710, -82223, -102686, -123086, -143413
        .long   -163654, -183795, -203827, -223735, -243508, -263135, -282604, -301902
        .long   -321018, -339941, -358659, -377161, -395436, -413473, -431261, -448789
        .long   -466046, -483023, -499709, -516094, -532168, -547921, -563345, -578429
        .long   -593164, -607543, -621555, -635193, -648448, -661313, -673779, -685840
        .long   -697487, -708715, -719515, -729882, -739809, -749291, -758321, -766895
        .long   -775007, -782651, -789825, -796522, -802740, -808474, -813721, -818478
        .long   -822743, -826511, -829782, -832552, -834822, -836588, -837851, -838608
        .long   -838861, -838608, -837851, -836588, -834822, -832552, -829782, -826511
        .long   -822743, -818478, -813721, -808474, -802740, -796522, -789825, -782651
        .long   -775007, -766895, -758321, -749291, -739809, -729882, -719515, -708715
        .long   -697487, -685840, -673779, -661313, -648448, -635193, -621555, -607543
        .long   -593164, -578429, -563345, -547921, -532168, -516094, -499709, -483023
        .long   -466046, -448789, -431261, -413473, -395436, -377161, -358659, -339941
        .long   -321018, -301902, -282604, -263135, -243508, -223735, -203827, -183795
        .long   -163654, -143413, -123086, -102686, -82223, -61710, -41161, -20587
        .balign 16
st:     .long   0, 0, 0, 0              | +0 busy, +1 lines pushed
phase:  .long   0, 0, 0, 0              | +16 per-slot phase
buf:    .space  256                     | +32 128 halfwords
