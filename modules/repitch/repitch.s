| REPITCH -- fifth TSTR value for STATIC/FLEX/PICKUP.
|
| Raw 4 uses the stock dry interpolator, but the playback increment shared by
| the ColdFire source supplier and DSP voice command is scaled by
| project_bpm24 / sample_bpm24. Existing values 0..3 retain their stock paths.
        .text

        .global tstr_fmt
        .global rate_hook
        .global grain_gate
        .global tempo_gate

| void fmt(char *buf, int raw). The caller already supplied sprintf's buf at
| 4(sp); replacing raw at 8(sp) with a format string makes the stock sprintf
| tail print it verbatim.
tstr_fmt:
        move.l  8(%sp),%d0
        cmpi.l  #4,%d0
        bhi.s   .unknown
        lea     .labels(%pc),%a0
        move.w  (%a0,%d0.l*2),%d1
        andi.l  #0xffff,%d1
        adda.l  %d1,%a0
        move.l  %a0,8(%sp)
        jmp     (0x40013a08).l
.unknown:
        lea     (0x400b442a).l,%a0        | stock "???"
        move.l  %a0,8(%sp)
        jmp     (0x40013a08).l

.labels:
        .word   .off-.labels,.auto-.labels,.norm-.labels,.beat-.labels
        .word   .repitch-.labels
.off:   .asciz  "OFF"
.auto:  .asciz  "AUTO"
.norm:  .asciz  "NORM"
.beat:  .asciz  "BEAT"
.repitch:
        .asciz  "REPITCH"
        .balign 2

| 0x40004100: finish stock pitch interpolation, then scale its Q-format
| increment for raw TSTR 4. fp is the current 48-byte playback lane; the
| current 40-byte state pointer identifies track 0..7, whose 168-byte voice
| owns the bound sample-settings pointer at +8.
rate_hook:
        .word   0xa1c0                    | displaced: movclr.l %acc0,%d0 (V4e)
        asr.l   %d6,%d0                  | displaced
        lea     -20(%sp),%sp
        movem.l %d1-%d4/%a0,(%sp)
        clr.l   %d1
        move.b  28(%fp),%d1
        cmpi.l  #4,%d1
        bne.s   .rate_restore
        move.l  0x800062a4,%d1
        subi.l  #0x80004898,%d1
        moveq   #40,%d2
        divu.l  %d2,%d1                  | current track
        cmpi.l  #7,%d1
        bhi.s   .rate_restore
        move.l  #168,%d2
        mulu.l  %d2,%d1
        lea     (0x800049d8).l,%a0
        movea.l 8(%a0,%d1.l),%a0         | sample settings
        move.l  %a0,%d1
        beq.s   .rate_restore
        move.l  0x114(%a0),%d2           | source BPM * 24
        beq.s   .rate_restore
        move.l  0x8000181c,%d3           | project BPM * 24
        beq.s   .rate_restore

| Exact integer (d0 * project) / source without overflowing the full product:
| q*project + ((remainder*project)/source).
        move.l  %d0,%d1
        divu.l  %d2,%d1                  | q = increment / source
        move.l  %d1,%d4
        mulu.l  %d2,%d4                  | q * source
        sub.l   %d4,%d0                  | remainder
        mulu.l  %d3,%d1                  | q * project
        mulu.l  %d3,%d0                  | remainder * project
        divu.l  %d2,%d0
        add.l   %d1,%d0
.rate_restore:
        movem.l (%sp),%d1-%d4/%a0
        lea     20(%sp),%sp
.rate_store:
        move.l  %d0,36(%a3)              | displaced; CPU and DSP both use it
        jmp     (0x40004108).l

| 0x40007ede: stock uses TSTR != 0 to enter its grain-state path. REPITCH is
| dry, like OFF, while AUTO/NORM/BEAT keep the original branch.
grain_gate:
        move.l  %d0,-(%sp)
        moveq   #4,%d0
        cmp.b   24(%a2),%d0
        bne.s   .grain_stock
        move.l  (%sp)+,%d0
        bra.s   .grain_dry
.grain_stock:
        move.l  (%sp)+,%d0
        tst.b   24(%a2)
        bne.s   .grain_wet
.grain_dry:
        clr.l   128(%a2)                 | displaced first dry-path instruction
        jmp     (0x40007ee8).l
.grain_wet:
        jmp     (0x40007f02).l

| 0x40008210: choose current effective tempo/reciprocal for OFF and REPITCH;
| AUTO/NORM/BEAT retain the sample-tempo grain values.
tempo_gate:
        move.l  %d0,-(%sp)
        moveq   #4,%d0
        cmp.b   24(%a2),%d0
        bne.s   .tempo_stock
        move.l  (%sp)+,%d0
        bra.s   .tempo_dry
.tempo_stock:
        move.l  (%sp)+,%d0
        tst.b   24(%a2)
        bne.s   .tempo_wet
.tempo_dry:
        movea.l -52(%fp),%a5
        move.w  %a0,%a3
        jmp     (0x4000822a).l
.tempo_wet:
        jmp     (0x4000821e).l
