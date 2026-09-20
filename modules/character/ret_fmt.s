| Character RET's display formatter (fmt(buf, value) -> the text). RET is
| live on the master only (T8, character.asm's position test), so off T8
| the knob is named "---" like an unused delay knob and prints no value;
| on T8 it is "RET" and its number. The page descriptor is one per effect, so the dial itself draws
| on every track; the name is the descriptor's 6-byte field at
| P + 0x16 + 6*slot (the MODE caves rewrite their neighbours' the same
| way), written here before the panel prints it. CLONE_CHARACTER is the
| clone's address, a build defsym. Current audio track = byte
| 0x80000000, 0..7 (MAINMENU.md).

        .text
fmt:    moveq   #0,%d0
        move.b  0x80000000,%d0          | current audio track
        lea     CLONE_CHARACTER+0x16+24,%a0   | slot 4's name field
        cmp.l   #7,%d0
        bne.s   blank
        move.l  #0x52455400,(%a0)       | "RET"
        clr.w   4(%a0)
        move.l  8(%sp),-(%sp)           | value
        pea     0x400b465d              | "%d"
        move.l  12(%sp),-(%sp)          | buf
        jsr     0x40013a08              | sprintf(buf, "%d", value)
        lea     12(%sp),%sp
        rts
blank:  move.l  #0x2d2d2d00,(%a0)       | "---", the unused-knob name
        clr.w   4(%a0)
        move.l  4(%sp),%a0              | buf
        clr.b   (%a0)                   | no value
        rts
