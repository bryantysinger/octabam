| PERSISTENT BUFFERS -- project-folder recorder buffers (REC1.wav..REC8.wav).
|
| On pstore_pre: mkdir BUFFERS/, sync-write each non-empty recorder
| (wav_write) to BUFFERS/RECn.wav, PATH it there, then stock flex
| post-load (no re-load — audio is already in the buffer; a SLOT_LOAD
| here re-read the WAV and the UI only updated when that finished).
| On load*_post / preload_post: PATH + flex slot load + post-load.
| Recorders are FLEX 128–135: use 0x40096548 / POST_LOAD(1, slot), not
| the static loader 0x40093980 (STORAGE.md's static entry; stock's flex
| caller at 0x40084b4a).
| Folder name has no '!': SLOT_LOAD treats '!BUFFERS/…' as INVALID FILENAME
| (PATH landed in project.work on R4/R5; UI stayed unassigned).
|
| Empty test: control record length at 0x46c922c4 + slot*44 + 16.

        .text
        .globl  pbf_st_pstore_pre, pbf_st_loadall_post, pbf_st_loadmask_post
        .globl  pbf_st_preload_post, pbf_st_answer
        .extern store_path

        .set    F_OPEN,     0x40016864
        .set    F_CLOSE,    0x4001677c
        .set    FLEX_LOAD,  0x40096548      | (slot, keep_trim) flex; recorders 128-135
        .set    POST_LOAD,  0x40099148      | (1, slot) after a flex load (0x40084b62)
        .set    REARM,      0x40093468      | (-1) re-arm voices
        .set    REFRESH,    0x4009da20      | (-1) refresh
        .set    SPRINTF,    0x40013a08
        .set    WAV_WRITE,  0x40020f04
        .set    MODE_R,     0x400b3289
        .set    MODE_W,     0x400b328b
        .set    SETTINGS,   0x100b14f0
        .set    SET_STRIDE, 0x448
        .set    CTL_BASE,   0x46c922c4
        .set    CTL_STRIDE, 44
        .set    CTL_LEN,    16
        .set    CTL_NAME,   24
        .set    WAV_GUARD,  0x46105408
        .set    FS_MKDIR,   0x46c8240a      | -> mkdir(path); call through
        .set    MIN_FRAMES, 64
        .set    MAX_FRAMES, 5292000
        .set    IOB_LEN,    0x10000

pbf_st_answer:
        rts

| ------------------------------------------------------------------ save
| Mkdir only when a non-empty slot will be written. An empty PROJECT SAVE
| used to call FS_MKDIR unconditionally; under the port that path hits
| unimplemented opcode 4ac8 (tas) and never returns. Lazy mkdir keeps the
| empty smoke green and avoids creating BUFFERS/ when nothing is saved.
pbf_st_pstore_pre:
        lea     %sp@(-40),%sp
        movem.l %d2-%d7/%a2-%a5,%sp@
        clrl    IDX
        clrl    MADE_DIR
sv_loop:
        movel   #128,%d3
        addl    IDX,%d3
        movel   %d3,SLOT
        bsr.w   slot_ctl
        movel   %a3@(CTL_LEN),%d5
        cmpl    #MIN_FRAMES,%d5
        bls.w   sv_next
        cmpl    #MAX_FRAMES,%d5
        bhi.w   sv_next
        movel   %d5,FRAMES
        tstl    MADE_DIR
        bne.s   sv_have_dir
        moveq   #0,%d0
        lea     FMT_DIR,%a0
        lea     PATH,%a1
        jsr     store_path
        moveal  FS_MKDIR,%a0
        pea     PATH
        jsr     %a0@
        addql   #4,%sp
        moveq   #1,%d0
        movel   %d0,MADE_DIR
sv_have_dir:
        moveq   #1,%d0
        addl    IDX,%d0
        lea     FMT_ABS,%a0
        lea     PATH,%a1
        jsr     store_path
        moveq   #1,%d0
        movel   %d0,WAV_GUARD
        pea     IOB_LEN
        pea     IOB
        pea     MODE_W:l
        pea     PATH
        pea     FO
        jsr     F_OPEN
        lea     %sp@(20),%sp
        tstl    %d0
        bmi.w   sv_next
        movel   SLOT,%sp@-
        movel   FRAMES,%sp@-
        clrl    %sp@-
        pea     FO
        jsr     WAV_WRITE
        lea     %sp@(16),%sp
        pea     FO
        jsr     F_CLOSE
        addql   #4,%sp
        bsr.w   bind_path               | PATH + UI; no re-load
sv_next:
        addql   #1,IDX
        moveq   #7,%d0
        cmpl    IDX,%d0
        bcc.w   sv_loop
        | One re-arm / refresh after the batch (STORAGE.md section 2).
        pea     -1
        jsr     REARM
        addql   #4,%sp
        pea     -1
        jsr     REFRESH
        addql   #4,%sp
        movem.l %sp@,%d2-%d7/%a2-%a5
        lea     %sp@(40),%sp
        rts

| ------------------------------------------------------------------ load
pbf_st_loadall_post:
pbf_st_loadmask_post:
pbf_st_preload_post:
        lea     %sp@(-40),%sp
        movem.l %d2-%d7/%a2-%a5,%sp@
        clrl    IDX
ld_loop:
        moveq   #1,%d0
        addl    IDX,%d0
        lea     FMT_ABS,%a0
        lea     PATH,%a1
        jsr     store_path
        pea     IOB_LEN
        pea     IOB
        pea     MODE_R:l
        pea     PATH
        pea     FO
        jsr     F_OPEN
        lea     %sp@(20),%sp
        tstl    %d0
        bmi.w   ld_next
        pea     FO
        jsr     F_CLOSE
        addql   #4,%sp
        movel   #128,%d3
        addl    IDX,%d3
        movel   %d3,SLOT
        bsr.w   load_slot
ld_next:
        addql   #1,IDX
        moveq   #7,%d0
        cmpl    IDX,%d0
        bcc.w   ld_loop
        pea     -1
        jsr     REARM
        addql   #4,%sp
        pea     -1
        jsr     REFRESH
        addql   #4,%sp
        movem.l %sp@,%d2-%d7/%a2-%a5
        lea     %sp@(40),%sp
        rts

| PATH into flex settings, ctl name, flex post-load — no file re-read.
| Same idea as BUFFER SAVER's mode-2 assign-to-self: the take is already
| in the buffer; only the binding and UI need updating.
bind_path:
        bsr.w   set_path
        bsr.w   set_ctl_name
        bsr.w   flex_post
        rts

| PATH + flex load from card + post-load (project load / reload).
load_slot:
        bsr.w   set_path
        clrl    %sp@-                   | keep_trim = 0
        movel   SLOT,%sp@-
        jsr     FLEX_LOAD
        addql   #8,%sp
        bsr.w   flex_post
        rts

set_path:
        movel   SLOT,%d3
        bsr.w   slot_settings
        moveq   #1,%d0
        addl    IDX,%d0
        lea     FMT_REL,%a0
        moveal  %a2,%a1
        movel   %d0,%sp@-
        movel   %a0,%sp@-
        movel   %a1,%sp@-
        jsr     SPRINTF
        lea     %sp@(12),%sp
        rts

| ctl+24 shows REC<n> so the slot list updates without a flex load.
set_ctl_name:
        movel   SLOT,%d3
        bsr.w   slot_ctl
        moveq   #1,%d0
        addl    IDX,%d0
        lea     FMT_NAME,%a0
        lea     %a3@(CTL_NAME),%a1
        movel   %d0,%sp@-
        movel   %a0,%sp@-
        movel   %a1,%sp@-
        jsr     SPRINTF
        lea     %sp@(12),%sp
        rts

| Stock flex caller: POST_LOAD(1, slot) then the batch re-arm/refresh.
flex_post:
        movel   SLOT,%sp@-
        pea     1
        jsr     POST_LOAD
        addql   #8,%sp
        rts

slot_settings:
        movel   %d3,%d0
        movel   #SET_STRIDE,%d1
        mulsl   %d1,%d0
        addil   #SETTINGS,%d0
        moveal  %d0,%a2
        rts

slot_ctl:
        movel   %d3,%d0
        movel   #CTL_STRIDE,%d1
        mulsl   %d1,%d0
        addil   #CTL_BASE,%d0
        moveal  %d0,%a3
        rts

        .data
        .align  4
FMT_DIR:  .asciz  "%s/BUFFERS"
FMT_ABS:  .asciz  "%s/BUFFERS/REC%d.wav"
FMT_REL:  .asciz  "BUFFERS/REC%d.wav"
FMT_NAME: .asciz  "REC%d"
        .align  4

        .section .bss
        .align  4
IDX:    .space  4
MADE_DIR: .space 4
SLOT:   .space  4
FRAMES: .space  4
PATH:   .space  260
FO:     .space  32
IOB:    .space  0x10000
