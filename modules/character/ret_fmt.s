| Character RET's display formatter (fmt(buf, value) -> sprintf). RET is
| live on the master only (T8, character.asm's position test), so on tracks
| 1-7 the knob prints "---" and on T8 its number. The page descriptor is one
| per effect, so the dial itself draws on every track; only the text is per
| track. Current audio track = byte 0x80000000, 0..7 (MAINMENU.md).
| Position-independent.

        .text
fmt:    moveq   #0,%d0
        move.b  0x80000000,%d0          | current audio track
        cmp.l   #7,%d0
        bne.s   blank
        move.l  8(%sp),-(%sp)           | value
        pea     0x400b465d              | "%d"
        move.l  12(%sp),-(%sp)          | buf
        jsr     0x40013a08              | sprintf(buf, "%d", value)
        lea     12(%sp),%sp
        rts
blank:  pea     dash(%pc)
        move.l  8(%sp),-(%sp)           | buf
        jsr     0x40013a08              | sprintf(buf, "---")
        addq.l  #8,%sp
        rts
dash:   .asciz  "---"
        .balign 4
