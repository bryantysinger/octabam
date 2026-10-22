| CX OSC -- ColdFire page cave. GNU as, -mcpu=5475. PINNED at 0x400d24d0:
| the override list (pg_over) carries absolute pointers to the formatters
| and widgets, so the bytes depend on the address. Forked from Tim Hastie's
| FM SYNTH page.s (timhastie/octatrick-modules v2.15 = 17ba281, MIT); see
| modules/cxosc/NOTICE. Resolved when the track is CX OSC (signature
| "CX", 1), not by a marker filename.
|
| WHAT: PLAYBACK presents PTCH RATO INDX FOLD SYMM FDBK (four-character
| names; boxes 19 px). RATO formats free 0.25..4; INDX/FOLD/SYMM/FDBK
| 0..127. Icons: operators (RATO), sidebands (INDX), fold/symmetry, FDBK
| loop. Footer CX OSC>FLEX. PTCH is semitones (−64..+63); RATE slot is
| FOLD (not FINE). Knobs: po_knob — one unit a detent, seven pressed;
| FUNC: PTCH 12 semitones, FOLD/SYMM/INDX/FDBK 16, RATO next classic
| snap ≤4.01. Non-CX tracks draw as stock.
|
| HOW: the page descriptor resolver 0x40031da4(track, page kind) returns
| tbl[machine] for the PLAYBACK page at 0x40031ece (`movel %a0@(0,%d0:l:4),%d0;
| bras 0x40031ed6`, 6 bytes -> `jmp pg_resolve`). Everything that draws or edits
| the page -- the generic parameter-page renderer 0x4004e0xx, the footer
| 0x4003d5xx, the knob handler 0x40055008 -- reaches the descriptor through it
| (0x40031ee0 / 0x40031f28 tail-call it). The stub replays the lookup and, for
| the FLEX descriptor of a track whose assigned FLEX slot (Part + 0x8f04a +
| track*5 + 1) has a settings record (0x100b14f0 + 0x448*slot) whose path's
| basename starts with "SYNTH" -- loaded into flex RAM or not -- returns the
| synth's descriptor: a RUNTIME CLONE of the stock FLEX record (P..P+0x192),
| built on first use by poly.s's po_pgdesc (the DRAM unit: the copy of the
| stock record from the image and the 402 B of RAM it needs live there; this
| cave has no room for them and, pinned at a fixed address, no way to name the
| unit -- so it takes the builder's address from the long before sy_render,
| whose own address the kind table's FLEX entry 0x400d6438 holds) with only
| the fields pg_over lists changed: the names, the title, the six A
| formatters (P+0xca), the four B widgets (P+0xfa), the enable nibbles
| (P+0x18e: 5/7 = bit 2 "always show the value") and, since the tuning
| system, PTCH's minimum and count (P+0x6a, P+0x9a: 0 and 128), FINE's
| default (P+0x5e+3: 64) and the two knob handlers (P+0x12a, +12: 0) --
| storage, locks, scenes, LFOs and MIDI reach the bytes exactly as before. The stock record itself is never written, and this file
| carries none of its bytes (26 Sep 2026: until then pg_desc was a copy of the
| 402-byte stock record with the fields patched, 347 of them Elektron's).
|
| The renderer draws each box at (x = 60/80/100, y = 36 top row / 8 bottom
| row; y grows UPWARD, screen row = 63 - y): the name centred on x+9 at y+20,
| then widget(x, y, slot, value, flags, fmt, window). With flags bit 3 (the
| nibble's bit 2) the stock dial 0x400479b4 clears the box, draws its circle
| bitmap at (x+4, y+7), the pointer at (x+6, y+9) and the value text centred
| at y+1. Each widget here calls the stock dial first (so the value text, the
| box clear and the lock highlight stay stock's) and then blits a 17 x 13
| column bitmap over the dial at (x+1, y+7) with 0x400128a8(bitmap, window,
| x, y): {width, height, longs per column, columns, mask}, one long per
| column, bit 31 = the bottom row, bit 31-k = row k above it; the blit does
| dst = (dst & ~mask) | (data & mask), so a full mask replaces the area. The
| icon is composed in a RAM scratch (pg_data; the main OS runs from DRAM)
| from static column images (pg_img_*) and a few procedural strokes.
| Formatters have the stock signature fmt(buf, value) -> sprintf.

        .text
        .global fm_descriptor, pg_resolve
        .set    RESOLVER_RET, 0x40031ed6
        .set    FLEX_P, 0x400d31ae       | the stock FLEX PLAYBACK descriptor (P form)
        .set    KIND_FLEX, 0x400d6438    | the kind table's FLEX entry: sy_render's address (the manifest's SymbolRef)
        .set    SLOT_OFF, 0x8f04b        | Part: 0x8f04a + track*5 + machine (1 = FLEX)
        .set    SETTINGS_BASE, 0x100b14f0
        .set    SETTINGS_STRIDE, 0x448
        .set    STOCK_WIDGET, 0x400479b4
        .set    BLIT, 0x400128a8
        .set    SPRINTF, 0x40013a08
        .set    FMT_D, 0x400b465d        | "%d"
        .set    FMT_PLAIN, 0x4003c178    | the stock formatter fmt(buf, value) -> sprintf(buf, "%d", value)

        .set    SIG_OFF, 0x8edbc         | Part NEIGHBOR PLAYBACK: "CX", 1 (machine.s)

| ---- CX OSC machine descriptor (machine.s fm_row RD_DESC; DRAM or cave) --------
fm_descriptor:
        moveal  KIND_FLEX,%a0            | sy_render
        moveal  %a0@(-4),%a0             | po_pgdesc
        lea     pg_over(%pc),%a1
        jmp     %a0@

| ---- the resolver (PLACE=DRAM: detour jmp; CAVE: jmp abs to cave+16) ----------
| 0x40031ece -> jmp pg_resolve. Signature "CX",1 in the Part (marker path off).
pg_resolve:
        movel   %a0@(0,%d0:l:4),%d0      | replay: the machine's descriptor
        cmpil   #FLEX_P,%d0
        bne     pg_r_done
        movel   #6322,%d2
        mulsl   %d1,%d2                  | part * 6322
        addl    %a1,%d2                  | + the bank blob
        moveal  %d2,%a0
        movel   %d3,%d4
        muluw   #30,%d4
        addal   %d4,%a0
        addal   #SIG_OFF,%a0
        mvzw    %a0@,%d5
        cmpil   #0x4358,%d5              | "CX"
        bne     pg_r_done
        mvzb    %a0@(2),%d5
        cmpil   #1,%d5
        bne     pg_r_done
        moveal  KIND_FLEX,%a0
        moveal  %a0@(-4),%a0             | po_pgdesc
        lea     pg_over(%pc),%a1
        jsr     %a0@
pg_r_done:
        jmp     RESOLVER_RET
        .align  4
| ---- what the clone changes: {offset.w, length.w, source.l} into the stock FLEX
| record, applied by po_pgdesc over its copy; a negative offset ends the list.
| Absolute pointers throughout: the cave is pinned.
pg_over:
        .short  0x009, 9
        .long   pg_title                 | P+0x009: the title, "CX OSC" (the footer reads CX OSC>FLEX)
        .short  0x01c, 30
        .long   pg_names                 | P+0x01c: slots 1..5 (STRT LEN RATE RTRG RTIM) read RATO INDX FINE FDBK DEC
        .short  0x061, 1
        .long   pg_def1                  | P+0x05e+3: FOLD's default, 1 (never stock RATE 0)
        .short  0x06a, 4
        .long   pg_zero                  | P+0x06a: PTCH's minimum, 0 (stock 4) ...
        .short  0x09a, 4
        .long   pg_l128                  | P+0x09a: ... and count, 128 (stock 121): raw 0..127 = -64..+63 semitones
        .short  0x0ca, 24
        .long   pg_fmts                  | P+0x0ca: the six A formatters
        .short  0x0fe, 8
        .long   pg_wids_a                | P+0x0fe: the B widgets of slots 1 2
        .short  0x10a, 8
        .long   pg_wids_b                | P+0x10a: of slots 4 5
        .short  0x12a, 4
        .long   pg_zero                  | P+0x12a: PTCH's knob handler, 0 (stock: the semitone-snapping
        .short  0x136, 4                 | accumulator 0x40032d08, built for 5 a semitone) ...
        .long   pg_zero                  | P+0x12a+12: FINE's, 0 (stock RATE: 0x400328e4) -- both moot since
                                         | 30 Sep 2026: po_pgdesc finishes the clone by planting poly.s's
                                         | po_knob in all six slots (one unit a detent, x7 pressed, FUNC's
                                         | per-knob jump; the DRAM unit's address is unknown to this cave)
        .short  0x18e, 4
        .long   pg_nibbles               | P+0x18e: the enable nibbles
        .short  -1, 0
        .long   0
pg_title:
        .asciz  "CX OSC"
pg_names:
        .ascii  "RATO\0\0INDX\0\0FOLD\0\0SYMM\0\0FDBK\0\0\0"
pg_def1:
        .byte   1
        .align  4
pg_zero:
        .long   0
pg_l128:
        .long   128
pg_fmts:
        .long   pg_fmt_ptch, pg_fmt_ratio, FMT_PLAIN, FMT_PLAIN, FMT_PLAIN, FMT_PLAIN
pg_wids_a:
        .long   pg_wid_ratio, pg_wid_index
pg_wids_b:
        .long   pg_wid_fdbk, pg_wid_decay
pg_nibbles:
        .long   0x55551551               | nibble s (from the LOW end, as 0x400a6994 shifts it) = slot
                                         | s; stock 0x55311311: bit 0 = the encoder is live, bit 1 (LEN,
                                         | RTIM) = the arch the renderer draws bridging the slot to the
                                         | one before it (STRT-LEN, RTRG-RTIM: cleared here, the pairs
                                         | mean nothing to the voice), bit 2 = always show the value
                                         | (set on 1 2 4 5). The first build set 0x55715751: RATE (s3)
                                         | always shown instead of FDBK (s4)

| ---- the formatters: fmt(buf, value), C convention ----------------------------
| INDEX and FDBK print 0..127 as stored through the stock's own "%d" formatter,
| FMT_PLAIN (26 Sep 2026: this cave's copy of it was the same 26 bytes).

pg_fmt_ptch:                             | PTCH on a synth track: raw - 64 as a signed whole number, "-12" "0" "+7"
        movel   %sp@(8),%d0              | raw
        subil   #64,%d0
        lea     pg_f_plus(%pc),%a0       | "+%d" above 0 ...
        bgt     pg_fp_go
        lea     FMT_D,%a0                | ... "%d" otherwise (0, and the minus sign is the number's own)
pg_fp_go:
        movel   %d0,%sp@-
        movel   %a0,%sp@-
        movel   %sp@(12),%sp@-           | buf
        jsr     SPRINTF
        lea     %sp@(12),%sp
        rts

pg_fmt_fine:                             | FINE: raw - 64 cents, "-64c" "0c" "+12c" (four characters at most)
        movel   %sp@(8),%d0
        subil   #64,%d0
        lea     pg_f_plusc(%pc),%a0      | "+%dc"
        bgt     pg_fp_go
        lea     pg_f_dc(%pc),%a0         | "%dc"
        bra     pg_fp_go

pg_fmt_ratio:                            | free RATO 0.25..4; exact classic Q8 at FUNC snap raws
        movel   %d2,%sp@-
        movel   %sp@(12),%d0             | raw
        lea     pg_snap_raw(%pc),%a0
        moveq   #0,%d1
pg_fr_hit:
        cmpb    %a0@(0,%d1:l),%d0
        beq     pg_fr_exact
        addql   #1,%d1
        cmpil   #16,%d1
        bcs     pg_fr_hit
        movel   #960,%d1                 | free map
        mulul   %d1,%d0
        movel   #127,%d1
        divul   %d1,%d0
        addil   #64,%d0
        bra     pg_fr_fmt
pg_fr_exact:
        lea     pg_snap_q8(%pc),%a0
        mvzw    %a0@(0,%d1:l:2),%d0
pg_fr_fmt:
        movel   %d0,%d1
        lsrl    #8,%d0
        andil   #255,%d1
        moveq   #100,%d2
        mulul   %d2,%d1
        lsrl    #8,%d1
        beq     pg_fr_int
        cmpil   #50,%d1
        beq     pg_fr_half
        movel   %d1,%sp@-
        movel   %d0,%sp@-
        pea     pg_f_dd(%pc)
        movel   %sp@(20),%sp@-
        jsr     SPRINTF
        lea     %sp@(16),%sp
        bra     pg_fr_out
pg_fr_half:
        movel   %d0,%sp@-
        pea     pg_f_d5(%pc)
        movel   %sp@(16),%sp@-
        jsr     SPRINTF
        lea     %sp@(12),%sp
        bra     pg_fr_out
pg_fr_int:
        movel   %d0,%sp@-
        pea     FMT_D
        movel   %sp@(16),%sp@-
        jsr     SPRINTF
        lea     %sp@(12),%sp
pg_fr_out:
        movel   %sp@+,%d2
        rts

pg_fmt_decay:                            | tau = 2 s * (raw/127)^2: "HOLD", "32", "286", "1.1s", "2.0s"
        movel   %d2,%sp@-
        movel   %sp@(12),%d0             | raw
        beq     pg_fd_hold
        movel   %d0,%d1
        mulul   %d0,%d1                  | raw^2
        movel   #2000,%d0
        mulul   %d1,%d0                  | * 2000 ms
        addil   #8064,%d0
        movel   #16129,%d1
        divul   %d1,%d0                  | / 127^2, rounded: ms
        cmpil   #1000,%d0
        bcc     pg_fd_sec
        movel   %d0,%sp@-
        pea     FMT_D                    | "%d": the milliseconds alone -- the value field
        movel   %sp@(16),%sp@-           | fits four characters and "598ms" ran into the divider
        jsr     SPRINTF
        lea     %sp@(12),%sp
        bra     pg_fd_out
pg_fd_sec:
        movel   #1000,%d1
        movel   %d0,%d2
        divul   %d1,%d2                  | seconds
        moveq   #100,%d1
        divul   %d1,%d0                  | tenths, total
        movel   %d2,%d1
        lsll    #3,%d1
        addl    %d2,%d1
        addl    %d2,%d1                  | seconds * 10
        subl    %d1,%d0                  | tenths
        movel   %d0,%sp@-
        movel   %d2,%sp@-
        pea     pg_f_s(%pc)              | "%d.%ds"
        movel   %sp@(20),%sp@-
        jsr     SPRINTF
        lea     %sp@(16),%sp
        bra     pg_fd_out
pg_fd_hold:
        pea     pg_f_hold(%pc)           | "HOLD": the index holds
        movel   %sp@(12),%sp@-
        jsr     SPRINTF
        addql   #8,%sp
pg_fd_out:
        movel   %sp@+,%d2
        rts

| ---- the widgets: widget(x, y, slot, value, flags, fmt, window) ---------------
pg_wid_ratio:
        moveq   #0,%d0
        bra     pg_wid
pg_wid_index:
        moveq   #1,%d0
        bra     pg_wid
pg_wid_fdbk:
        moveq   #2,%d0
        bra     pg_wid
pg_wid_decay:
        moveq   #3,%d0
        bra     pg_wid
pg_wid:
        lea     %sp@(-44),%sp
        moveml  %d2-%d7/%a2-%a6,%sp@     | args: 48 x, 52 y, 56 slot, 60 value, 64 flags, 68 fmt, 72 window
        movel   %d0,%d7                  | which icon
        movel   %sp@(72),%sp@-           | the stock dial first: the box clear, the value text,
        movel   %sp@(72),%sp@-           | the lock highlight (each push brings the next arg to 72)
        movel   %sp@(72),%sp@-
        movel   %sp@(72),%sp@-
        movel   %sp@(72),%sp@-
        movel   %sp@(72),%sp@-
        movel   %sp@(72),%sp@-
        jsr     STOCK_WIDGET
        lea     %sp@(28),%sp
        movel   %sp@(64),%d0             | flags bit 1 = the compact layout (CHROMATIC trig mode's
        btst    #1,%d0                   | half-height page: the stock prints the value alone at
        bne     pg_wid_out               | 0x40047a42) -- no room for an icon, leave the box as drawn
        movel   %sp@(60),%d6             | value
        tstl    %d7
        beq     pg_ic_ratio
        subql   #1,%d7
        beq     pg_ic_index
        subql   #1,%d7
        beq     pg_ic_fdbk
        bra     pg_ic_decay

| RATIO: the two operators, M -> C (the ratio itself is the value text)
pg_ic_ratio:
        lea     pg_img_ratio(%pc),%a0
        bsr     pg_copy
        bra     pg_blit

| INDEX: a sideband spectrum -- the carrier bar shrinks a little, the sidebands
| at +-1, +-2, +-3 grow in turn with the index (a Bessel-shaped cartoon)
pg_ic_index:
        lea     pg_img_base(%pc),%a0
        bsr     pg_copy
        movel   %d6,%d1
        moveq   #3,%d0
        mulul   %d0,%d1
        moveq   #127,%d0
        divul   %d0,%d1                  | value * 3 / 127
        moveq   #11,%d2
        subl    %d1,%d2                  | the carrier, 11 .. 8
        moveq   #8,%d0
        moveq   #1,%d1
        bsr     pg_vline
        movel   %d6,%d2
        moveq   #10,%d0
        mulul   %d0,%d2
        moveq   #127,%d0
        divul   %d0,%d2                  | +-1: value * 10 / 127
        beq     pg_ix2
        moveq   #6,%d0
        moveq   #1,%d1
        bsr     pg_vline
        moveq   #10,%d0
        moveq   #1,%d1
        bsr     pg_vline
pg_ix2:
        movel   %d6,%d2
        subil   #20,%d2
        ble     pg_ix3
        moveq   #8,%d0
        mulul   %d0,%d2
        movel   #107,%d0
        divul   %d0,%d2                  | +-2: (value - 20) * 8 / 107
        beq     pg_ix3
        moveq   #4,%d0
        moveq   #1,%d1
        bsr     pg_vline
        moveq   #12,%d0
        moveq   #1,%d1
        bsr     pg_vline
pg_ix3:
        movel   %d6,%d2
        subil   #56,%d2
        ble     pg_blit
        moveq   #6,%d0
        mulul   %d0,%d2
        moveq   #71,%d0
        divul   %d0,%d2                  | +-3: (value - 56) * 6 / 71
        beq     pg_blit
        moveq   #2,%d0
        moveq   #1,%d1
        bsr     pg_vline
        moveq   #14,%d0
        moveq   #1,%d1
        bsr     pg_vline
        bra     pg_blit

| FDBK: the modulator, and its feedback loop when the value is not 0
pg_ic_fdbk:
        lea     pg_img_fdbk(%pc),%a0
        bsr     pg_copy
        tstl    %d6
        beq     pg_blit
        lea     pg_img_loop(%pc),%a0
        bsr     pg_or
        bra     pg_blit

| DECAY: the index envelope -- an instant rise at column 1, then pg_env's
| exponential fall stretched over L = 2 + value * 13 / 127 columns to the
| floor (row 1 = I/16), columns 2..15; value 0 holds, a flat top
pg_ic_decay:
        lea     pg_img_base(%pc),%a0
        bsr     pg_copy
        moveq   #1,%d0
        moveq   #1,%d1
        moveq   #11,%d2
        bsr     pg_vline                 | the attack edge
        movel   #0x7fff,%d5              | value 0: i stays 0, h stays 11
        tstl    %d6
        beq     pg_dc_go
        movel   %d6,%d5
        moveq   #13,%d0
        mulul   %d0,%d5
        moveq   #127,%d0
        divul   %d0,%d5
        addql   #2,%d5                   | L, 2 .. 15 columns
pg_dc_go:
        moveq   #11,%d4                  | the previous height
        moveq   #2,%d7                   | column, 2 .. 15
pg_dc_loop:
        movel   %d7,%d2
        subql   #1,%d2
        lsll    #4,%d2
        divul   %d5,%d2                  | i = (c - 1) * 16 / L
        cmpil   #16,%d2
        ble     pg_dc1
        moveq   #16,%d2
pg_dc1:
        lea     pg_env(%pc),%a0
        mvzb    %a0@(0,%d2:l),%d2        | h
        moveal  %d2,%a3
        movel   %d7,%d0
        movel   %d2,%d1
        movel   %d4,%d2
        bsr     pg_vline                 | rows h .. previous: the outline
        movel   %a3,%d4
        addql   #1,%d7
        cmpil   #15,%d7
        ble     pg_dc_loop

| the blit: over the stock dial, at (x+1, y+7); inverted with the box when
| the parameter is locked (flags bit 0: the stock inverts x+1..x+17, y+1..y+18)
pg_blit:
        movel   %sp@(64),%d0
        btst    #0,%d0
        beq     pg_blit1
        lea     pg_data(%pc),%a0
        moveq   #16,%d0
pg_inv:
        movel   %a0@,%d1
        eoril   #0xfff00000,%d1          | rows 0..11 (row 12, y+19, lies outside the highlight)
        movel   %d1,%a0@+
        subql   #1,%d0
        bge     pg_inv
pg_blit1:
        movel   %sp@(52),%d0
        addql   #7,%d0
        movel   %d0,%sp@-                | y + 7
        movel   %sp@(52),%d0
        addql   #1,%d0
        movel   %d0,%sp@-                | x + 1
        movel   %sp@(80),%sp@-           | window
        pea     pg_bmp(%pc)
        jsr     BLIT
        lea     %sp@(16),%sp
pg_wid_out:
        moveml  %sp@,%d2-%d7/%a2-%a6
        lea     %sp@(44),%sp
        rts

| ---- icon helpers (the scratch is pg_data: 17 longs, one per column) -------
pg_copy:                                 | a0 = a 17-column image -> the scratch
        lea     pg_data(%pc),%a1
        moveq   #16,%d0
pg_copy1:
        movel   %a0@+,%a1@+
        subql   #1,%d0
        bge     pg_copy1
        rts
pg_or:                                   | OR the image at a0 into the scratch
        lea     pg_data(%pc),%a1
        moveq   #16,%d0
pg_or1:
        movel   %a0@+,%d1
        orl     %d1,%a1@+
        subql   #1,%d0
        bge     pg_or1
        rts
pg_vline:                                | column d0, rows d1 .. d2 (d1 <= d2 <= 12); clobbers d1, d3, a0
        lea     pg_data(%pc),%a0
        lea     %a0@(0,%d0:l:4),%a0
        movel   #0x80000000,%d3
        lsrl    %d1,%d3
pg_vline1:
        orl     %d3,%a0@
        lsrl    #1,%d3
        addql   #1,%d1
        cmpl    %d1,%d2
        bge     pg_vline1
        rts

| ---- data -------------------------------------------------------------------
pg_f_dd:
        .asciz  "%d.%02d"
pg_f_d5:
        .asciz  "%d.5"
pg_f_s:
        .asciz  "%d.%ds"
pg_f_hold:
        .asciz  "HOLD"
pg_f_plus:
        .asciz  "+%d"
pg_f_plusc:
        .asciz  "+%dc"
pg_f_dc:
        .asciz  "%dc"
pg_env:                                  | 11 * exp(-i/5), i = 0..16; the floor is row 1
        .byte   11, 9, 7, 6, 5, 4, 3, 3, 2, 2, 1, 1, 1, 1, 1, 1, 1
        .align  2
pg_snap_q8:                              | classic FM ratios <= 4.01 (Q8); matches poly.s sy_rato_snap
        .short  64, 128, 192, 256, 259, 320, 362, 384
        .short  448, 512, 515, 640, 768, 896, 1024, 1027
pg_snap_raw:                             | rounded raw for each; matches poly.s sy_rato_snap_raw
        .byte   0, 8, 17, 25, 26, 34, 39, 42
        .byte   51, 59, 60, 76, 93, 110, 127, 127
        .align  2
pg_bmp:                                  | the blit's record: width, height, longs per column, columns, mask
        .long   17, 13, 1, pg_data, pg_mask
pg_mask:
        .rept   17
        .long   0xfff80000               | rows 0..12
        .endr
pg_data:                                 | the scratch (RAM)
        .fill   17, 4, 0


| RATO: the two operators, a box each, the modulator feeding the carrier
pg_img_ratio:
|   .................
|   .................
|   .................
|   .................
|   ..####.....####..
|   ..#..#..#..#..#..
|   ..#..#...#.#..#..
|   ..#..#######..#..
|   ..#..#...#.#..#..
|   ..#..#..#..#..#..
|   ..####.....####..
|   .................
|   .................
        .long   0x00000000, 0x00000000, 0x3f800000, 0x20800000
        .long   0x20800000, 0x3f800000, 0x04000000, 0x04000000
        .long   0x15000000, 0x0e000000, 0x04000000, 0x3f800000
        .long   0x20800000, 0x20800000, 0x3f800000, 0x00000000
        .long   0x00000000

| FDBK: the modulator's box; pg_img_loop is OR'd over it when FDBK > 0
pg_img_fdbk:
|   .................
|   .................
|   .................
|   .................
|   .....#######.....
|   .....#.....#.....
|   .....#.....#.....
|   .....#.....#.....
|   .....#.....#.....
|   .....#.....#.....
|   .....#######.....
|   .................
|   .................
        .long   0x00000000, 0x00000000, 0x00000000, 0x00000000
        .long   0x00000000, 0x3f800000, 0x20800000, 0x20800000
        .long   0x20800000, 0x20800000, 0x20800000, 0x3f800000
        .long   0x00000000, 0x00000000, 0x00000000, 0x00000000
        .long   0x00000000

| the feedback loop: out of the box's right side, over the top, back into
| its left side with an arrowhead
pg_img_loop:
|   .................
|   ..############...
|   ..#..........#...
|   ..#..........#...
|   ..#..........#...
|   ..#..........#...
|   ..##.........#...
|   ..###.......##...
|   ...#.............
|   .................
|   .................
|   .................
|   .................
        .long   0x00000000, 0x00000000, 0x07f00000, 0x0e100000
        .long   0x04100000, 0x00100000, 0x00100000, 0x00100000
        .long   0x00100000, 0x00100000, 0x00100000, 0x00100000
        .long   0x04100000, 0x07f00000, 0x00000000, 0x00000000
        .long   0x00000000

| the baseline of INDX and DEC: columns 1..15, a pixel clear of the box edges
pg_img_base:
|   .................
|   .................
|   .................
|   .................
|   .................
|   .................
|   .................
|   .................
|   .................
|   .................
|   .................
|   .................
|   .###############.
        .long   0x00000000, 0x80000000, 0x80000000, 0x80000000
        .long   0x80000000, 0x80000000, 0x80000000, 0x80000000
        .long   0x80000000, 0x80000000, 0x80000000, 0x80000000
        .long   0x80000000, 0x80000000, 0x80000000, 0x80000000
        .long   0x00000000

        .align  4
pg_end:
