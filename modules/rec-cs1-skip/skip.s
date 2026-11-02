| REC CS1 SKIP -- stock 0x4000432c (the recorder control-record update the
| write path calls, ~1.5 times a recording track a frame) with two of its
| six CS1 writes skipped when CS1 already holds the value. Everything else is
| stock's, instruction for instruction (RECORDER.md; 1 Nov 2026):
|
|   a1 = len, floored at 64 when non-zero; [0x46c938c4 + 44*id + 16] = a1
|   unless flag or len == 0: with r = 0x100d38f0 + 1096*id (CS1),
|     d2 = max(len, 0); d3 = min(max([r+300], 0), d2)
|     d1 = min(max(len, d3), d2);  a1 = min(max([r+308], d3), d1)
|     under 0x2700: [r+300] = d3, [r+304] = d1, [r+308] = a1
|     [r+296].b = 0; under 0x2700: [r+276] = [0x8000181c], [r+280] = -[0x80001820]
|
| CS1 is slow (PC SAMPLER on Bryan T's MKII: about 0.5 us a read or a write,
| reads and writes alike), and in steady play the port saw 358,300 of
| 358,316 of these writes store the value already there. [r+300] and [r+308]
| are already read for the arithmetic, so comparing them costs nothing: the
| write is skipped when the read value equals the new one, and the memory
| ends as stock leaves it. Nothing above level 5 writes these fields (the
| port's writers: this routine, the write path, project load, the engine
| and arm tasks, which cannot run inside the frame interrupt), so the value
| read is the value the write would replace. The other four writes would
| need a read each to skip, which costs what the write does: left as stock.
| SPDX-License-Identifier: MIT
        .set    RCS_MIRROR, 1                   | 0: option 1 alone (the two writes it reads for)
        .text
        .globl  rcs_update
| jmp'd in place of the routine's first two instructions: the whole routine.
| Args (C): id 4(sp), len 8(sp), flag 12(sp); d2-d5/a2-a3 saved here (stock
| saves d2-d3; the rest are this version's).
|
| RCS_MIRROR (option 2) skips the other four writes too ([r+276], [r+280],
| [r+296].b, [r+304]) against a copy in DRAM, rcs_m[id] = {valid, 276, 280,
| 304, 296, turn}, for id 0..7 (any other id writes all four, as stock). A
| copy can go stale when other code writes CS1 (project load, the engine and
| arm tasks: the port saw six such writers, and a static search finds 87
| candidate stores at these offsets), so each call reads ONE of the four from
| CS1, in turn, and a mismatch drops the copy: the next write writes all four
| again. One read a call against up to four writes; a foreign value survives
| at most four calls (about a millisecond at one call a frame) where stock
| would overwrite it at the next call.
rcs_update:
        lea     -24(%sp),%sp
        movem.l %d2-%d5/%a2-%a3,(%sp)
        move.l  28(%sp),%d1                     | id
        movea.l 32(%sp),%a1                     | len
        tst.l   %a1
        beq.s   1f
        moveq   #64,%d0
        cmp.l   %a1,%d0
        ble.s   1f
        movea.w #64,%a1
1:      moveq   #44,%d0
        muls.l  %d1,%d0
        lea     0x46c938c4,%a0
        move.l  %a1,16(%a0,%d0.l)
        tst.l   36(%sp)                         | flag
        bne     9f
        tst.l   %a1
        beq     9f
        move.l  #1096,%d0
        muls.l  %d1,%d0
        movea.l %d0,%a0
        adda.l  #0x100d38f0,%a0
        move.l  %a1,%d2
        bge.s   2f
        clr.l   %d2
2:      move.l  300(%a0),%d1
        move.l  %d1,%d4                         | [r+300] as read
        move.l  %d1,%d0                         | max(d1, 0), as stock does it
        not.l   %d0
        add.l   %d0,%d0
        subx.l  %d0,%d0
        and.l   %d0,%d1
        move.l  %d2,%d3
        cmp.l   %d2,%d1
        bge.s   3f
        move.l  %d1,%d3
3:      move.l  %d3,%d1
        cmpa.l  %d3,%a1
        ble.s   4f
        move.l  %a1,%d1
4:      cmp.l   %d1,%d2
        bge.s   5f
        move.l  %d2,%d1
5:      movea.l 308(%a0),%a2                    | [r+308] as read
        move.l  %d3,%d0
        cmpa.l  %d3,%a2
        ble.s   6f
        move.l  %a2,%d0
6:      movea.l %d1,%a1
        cmp.l   %d1,%d0
        bge.s   7f
        movea.l %d0,%a1
| the copy: a3 = &rcs_m[id] for id 0..7, else 0; d2 = 1 when the copy is
| valid and the field read in turn still matches it, else 0
7:      suba.l  %a3,%a3
        moveq   #0,%d2
.if RCS_MIRROR
        move.l  28(%sp),%d0
        moveq   #8,%d5
        cmp.l   %d5,%d0
        bcc.s   20f                             | unsigned: 0..7 only
        move.l  %d0,%d5                         | id * 24
        lsl.l   #3,%d0
        lsl.l   #4,%d5
        add.l   %d5,%d0
        lea     rcs_m,%a3
        adda.l  %d0,%a3
        move.l  (%a3),%d2                       | valid
        move.l  20(%a3),%d5                     | turn
        addq.l  #1,20(%a3)
        moveq   #3,%d0
        and.l   %d0,%d5
        beq.s   11f
        subq.l  #1,%d5
        beq.s   12f
        subq.l  #1,%d5
        beq.s   13f
        moveq   #0,%d0                          | turn 3: [r+296].b
        move.b  296(%a0),%d0
        cmp.l   16(%a3),%d0
        bra.s   19f
11:     move.l  276(%a0),%d0
        cmp.l   4(%a3),%d0
        bra.s   19f
12:     move.l  280(%a0),%d0
        cmp.l   8(%a3),%d0
        bra.s   19f
13:     move.l  304(%a0),%d0
        cmp.l   12(%a3),%d0
19:     beq.s   20f
        moveq   #0,%d2                          | CS1 changed under the copy: write all four
20:
.endif
        move.w  %sr,%d0
        move.w  #0x2700,%sr
        cmp.l   %d4,%d3
        beq.s   71f
        move.l  %d3,300(%a0)
71:     tst.l   %d2
        beq.s   73f
        cmp.l   12(%a3),%d1
        beq.s   74f
73:     move.l  %d1,304(%a0)
        move.l  %a3,%d5
        beq.s   74f
        move.l  %d1,12(%a3)
74:     cmpa.l  %a2,%a1
        beq.s   72f
        move.l  %a1,308(%a0)
72:     move.w  %d0,%sr
        tst.l   %d2
        beq.s   75f
        tst.l   16(%a3)
        beq.s   76f
75:     clr.b   296(%a0)
        move.l  %a3,%d5
        beq.s   76f
        clr.l   16(%a3)
76:     move.w  %sr,%d0
        move.w  #0x2700,%sr
        move.l  0x8000181c,%d1
        tst.l   %d2
        beq.s   77f
        cmp.l   4(%a3),%d1
        beq.s   78f
77:     move.l  %d1,276(%a0)
        move.l  %a3,%d5
        beq.s   78f
        move.l  %d1,4(%a3)
78:     move.l  0x80001820,%d1
        neg.l   %d1
        tst.l   %d2
        beq.s   79f
        cmp.l   8(%a3),%d1
        beq.s   80f
79:     move.l  %d1,280(%a0)
        move.l  %a3,%d5
        beq.s   80f
        move.l  %d1,8(%a3)
80:     move.w  %d0,%sr
        move.l  %a3,%d5
        beq.s   9f
        moveq   #1,%d5
        move.l  %d5,(%a3)                       | the copy now matches CS1
9:      movem.l (%sp),%d2-%d5/%a2-%a3
        lea     24(%sp),%sp
        rts

        .bss
        .balign 4
| rcs_m[8]: {valid, [r+276], [r+280], [r+304], [r+296].b, turn}; zero at boot = not valid
rcs_m:  .space  8*24
