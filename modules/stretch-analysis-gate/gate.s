| STRETCH ANALYSIS GATE: the sample analyzer task (0x40098a5c, priority 1)
| skips a voice whose resolved time-stretch mode is off.
|
| The task walks the eight voices; for each playing FLEX, STATIC or PICKUP
| voice it copies the voice record (0x800049d8 + 168 x t, 168 bytes) to
| 44(sp), refreshes the voice's entry in the table 0x80006924 (8 bytes a
| voice) and analyses its sample in 512-unit chunks (0x400985ac). The only
| readers of that work are the voice renderer's time-stretch branches
| (0x40008250 forward, 0x40008a1a reverse), which run only when the voice's
| resolved TSTR, voice +24 (docs/firmware/REPITCH.md), is non-zero. With it
| zero the work is never read.
|
| Hooked at 0x40098b2c, the table check after the copy: `movea.l (a3),a0;
| cmpa.l 188(sp),a0; beq.s 0x40098b5e` (8 bytes). The copy's +24 is 68(sp).
| Zero: on to the task's own next-voice path (0x40098cc8), as stock does for
| a voice it does not analyse; this voice's pending bit stays clear, so the
| task sleeps once no voice is pending. Non-zero: the displaced three
| instructions, replayed.
|
| A voice that is skipped keeps its table entry and analysis state as they
| were, as stock leaves them for any voice it skips. When its TSTR turns on,
| the next pass refreshes the entry and the renderer's own match on it
| (0x4000825e / 0x40008a24) decides whether an entry applies.

        .equ    NEXT_VOICE, 0x40098cc8      | the task's loop increment
        .equ    KEY_DIFF,   0x40098b34      | after the displaced beq, not taken
        .equ    KEY_SAME,   0x40098b5e      | the displaced beq's target

        .text
        .global sag_gate
sag_gate:
        tst.b   68(%sp)                     | the copied voice's resolved TSTR
        bne.s   1f
        jmp     NEXT_VOICE
1:      move.l  (%a3),%a0                   | displaced
        cmpa.l  188(%sp),%a0                | displaced
        beq.s   2f
        jmp     KEY_DIFF
2:      jmp     KEY_SAME
