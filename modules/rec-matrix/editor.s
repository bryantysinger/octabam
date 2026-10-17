| REC MATRIX editor: the trig keys edit the active track's recorder row.
|
| Open: knob E pushed on RECORDING SETUP 1 while SRC3 shows MTRX. Both
| RECORDING SETUP key layers (MKI 0x400b9e36, MKII 0x400b9e22) carry a
| knob-E record whose press handler stock leaves 0 (swallowed); the manifest
| points it at rmx_knob_e. Opening registers rmx_layer on top of the
| setup's: the trigs toggle sources, NO or knob E closes, the six knobs are
| swallowed; every other key falls through (track keys still change the
| active track, and the editor follows it). The setup window's redraw
| (0x4002f2f8) redraws the editor's own full-screen window (128 x 64, level 2,
| over the level-1 setup window) while it is open, and the trig-LED refresh
| (0x40043fdc) shows the row. The setup window's close
| (0x4002ee88) closes the editor first, so its layer never outlives it.
|
| Trigs (Bryan T): 1 AB, 2 CD, 3 MAIN, 4 CUE, 5 A, 6 B, 7 C, 8 D, 9..16
| T1..T8. A press turns its source on or off; turning AB on turns A and B
| off and turning A or B on turns AB off (the same for CD, C, D), so the
| row never holds both a pair and one of its inputs. An edit goes to BRAIN's
| value (REC<n>) and is saved as a SETTINGS edit is (brain_post_settings).

        .equ    WINDOW,     0x460d10cc      | the open SETUP window's object, 0 when closed
        .equ    SETUP_PAGE, 0x460d115e      | 0 RECORDING SETUP 1, 1 SETUP 2
        .equ    CUR_TRACK,  0x100b14cc      | the active track, 0..7
        .equ    CUR_PART,   0x100b14cf      | the current Part
        .equ    BANK_PTR,   0x46c82456      | the current bank's blob
        .equ    REC_SRC3,   0x8f386         | track 0's SRC3 byte in the Part (setup + 4)
        .equ    SRC3_MTRX,  11              | MTRX as stored
        .equ    LAYER_ADD,  0x40031494      | register a key layer
        .equ    LAYER_DEL,  0x4003146c      | remove one
        .equ    SPRINTF,    0x40013a08
        .equ    SET_TITLE,  0x40057c84      | (window, title, 0)
        .equ    CLEAR_BODY, 0x400356a8      | (surface): the window's interior cleared
        .equ    DRAWSTR,    0x40012bd8      | (font, surface, x, y, -1, str)
        .equ    INVERT,     0x40012254      | (surface, x0, y0, x1, y1, ink)
        .equ    TEXT_W,     0x40012f30      | (font, -1, str): pixels
        .equ    FONT,       0x400ba876
        .equ    SET_LED,    0x40013784      | (id, ticks); 0 turns it off
        .equ    LED_LEVEL,  0x400135b0      | (id, level)
        .equ    LED_NOBLINK, 0x400131c8     | (id)
        .equ    WIN_NEW,    0x4005829c      | (w, h, -1, 0, level, close_fn): a window object
        .equ    WIN_FREE,   0x40055db4      | (&object): the window closed, the pointer cleared
        .equ    DRAW_CONT,  0x4002f300      | the setup redraw after its link/movem
        .equ    LEDS_CONT,  0x40043fe4      | the trig-LED refresh after its lea/movem
        .equ    LEDS_SITE,  0x40043fdc      | the trig-LED refresh: (track)
        .equ    CLOSE_CONT, 0x4002ee90      | the setup close after `move.l a2,-(sp); tst.l WINDOW`

| mask bits: 0 A, 1 B, 2 C, 3 D, 4 AB, 5 CD, 6..13 T1..T8, 14 MAIN, 15 CUE
        .equ    M_A,  0x0001
        .equ    M_B,  0x0002
        .equ    M_C,  0x0004
        .equ    M_D,  0x0008
        .equ    M_AB, 0x0010
        .equ    M_CD, 0x0020

        .text

| ---- state ------------------------------------------------------------------

        .global rmx_editing
| rmx_editing lives in .data below (a long, 0 or 1).

| d0 = the active track's recorder mask pointer (a long in BRAIN's table).
rmx_cur_ptr:
        moveq   #0,%d0
        move.b  (CUR_TRACK).l,%d0
        lea     rmx_mask_ptr,%a0
        move.l  (%a0,%d0.l*4),%d0
        rts

| d0 = 1 if the active track's SRC3 (as stored in the current Part) is MTRX.
rmx_is_mtrx:
        move.l  %d2,-(%sp)
        bsr.s   rmx_is_mtrx_body
        move.l  (%sp)+,%d2
        rts
rmx_is_mtrx_body:
        moveq   #0,%d0
        move.b  (CUR_TRACK).l,%d0
        move.l  %d0,%d1
        lsl.l   #2,%d1                      | 4t
        lsl.l   #4,%d0                      | 16t
        sub.l   %d1,%d0                     | 12t
        moveq   #0,%d1
        move.b  (CUR_PART).l,%d1
        move.l  %d0,%a0
        move.l  #6322,%d0
        muls.l  %d0,%d1
        add.l   %a0,%d1
        add.l   (BANK_PTR).l,%d1
        add.l   #REC_SRC3,%d1
        move.l  %d1,%a0
        moveq   #0,%d1
        move.b  (%a0),%d1
        moveq   #0,%d0
        moveq   #SRC3_MTRX,%d2
        cmp.l   %d2,%d1
        bne.s   1f
        moveq   #1,%d0
1:      rts

| ---- open and close ---------------------------------------------------------

| Knob E's press on RECORDING SETUP (both models' layers): (code, edge).
        .global rmx_knob_e
rmx_knob_e:
        tst.l   (WINDOW).l
        beq.s   9f
        tst.l   (SETUP_PAGE).l              | SETUP 1 only
        bne.s   9f
        bsr     rmx_is_mtrx
        tst.l   %d0
        beq.s   9f
        tst.l   rmx_editing
        bne.s   9f
| The window first: opening it runs the close callback of every window of
| level 2 or more the manager still lists, including this editor's last
| one (freeing a window does not unlist it), so nothing of the editor may
| be live yet; rmx_win_closed ignores a call with no window.
        pea     rmx_win_closed              | its own window over RECORDING SETUP:
        pea     2                           | level 2 leaves the level-1 setup window open
        clr.l   -(%sp)
        pea     -1
        pea     64
        pea     128
        jsr     (WIN_NEW).l
        lea     24(%sp),%sp
        move.l  %d0,rmx_win
        moveq   #1,%d0
        move.l  %d0,rmx_editing
        pea     rmx_layer
        jsr     (LAYER_ADD).l
        addq.l  #4,%sp
        bsr     rmx_draw
        bsr     rmx_leds
9:      rts

| Closes the editor if it is open: the layer removed, the LEDs handed back.
        .global rmx_close
rmx_close:
        tst.l   rmx_editing
        beq.s   9f
        clr.l   rmx_editing
        pea     rmx_layer
        jsr     (LAYER_DEL).l
        addq.l  #4,%sp
        tst.l   rmx_win
        beq.s   1f
        pea     rmx_win
        jsr     (WIN_FREE).l
        addq.l  #4,%sp
        clr.l   rmx_win
1:      bsr     rmx_leds_off
        moveq   #0,%d0                      | stock's refresh redraws its own LEDs
        move.b  (CUR_TRACK).l,%d0
        move.l  %d0,-(%sp)
        jsr     (LEDS_SITE).l
        addq.l  #4,%sp
9:      rts

| NO or knob E inside the editor: (code, edge).
rmx_key_close:
        bra     rmx_close

| The window manager closed the editor's window (another window opened).
| Called for this editor's current window, or for an earlier one still listed
| (on the next window's opening): with no window open it does nothing, as
| stock's setup close (0x4002ee88) does with no setup window.
rmx_win_closed:
        tst.l   rmx_win
        beq.s   9f
        clr.l   rmx_win                     | already gone: not freed twice
        bra     rmx_close
9:      rts

| 0x4002ee88, a "jmp" detour: the setup window's close. The editor closes
| first; then the displaced `move.l a2,-(sp); tst.l WINDOW`, whose flags
| the stock branch at 0x4002ee90 reads.
        .global rmx_on_close
rmx_on_close:
        bsr     rmx_close
        move.l  %a2,-(%sp)
        tst.l   (WINDOW).l
        jmp     (CLOSE_CONT).l

| ---- the trigs --------------------------------------------------------------

| A trig's press inside the editor: (code, edge); code 0..15.
rmx_trig:
        move.l  4(%sp),%d0
        moveq   #15,%d1
        cmp.l   %d1,%d0
        bhi.s   9f
        lea     rmx_trig_bit,%a0
        moveq   #0,%d1
        move.w  (%a0,%d0.l*2),%d1           | d1 = the trig's source bit
        move.l  %d2,-(%sp)
        bsr     rmx_cur_ptr
        move.l  %d0,%a1                     | a1 = the recorder's value (a long)
        move.l  (%a1),%d0
        and.l   #0xffff,%d0
        move.l  %d0,%d2
        and.l   %d1,%d2
        bne.s   2f                          | it was on: turn it off
        or.l    %d1,%d0                     | on, then the exclusions
        cmp.l   #M_AB,%d1
        bne.s   3f
        and.l   #0xfffffffc,%d0             | A, B off
3:      cmp.l   #M_A,%d1
        beq.s   4f
        cmp.l   #M_B,%d1
        bne.s   5f
4:      and.l   #0xffffffef,%d0             | AB off
5:      cmp.l   #M_CD,%d1
        bne.s   6f
        and.l   #0xfffffff3,%d0             | C, D off
6:      cmp.l   #M_C,%d1
        beq.s   7f
        cmp.l   #M_D,%d1
        bne.s   8f
7:      and.l   #0xffffffdf,%d0             | CD off
        bra.s   8f
2:      eor.l   %d1,%d0
8:      ext.l   %d0                         | BRAIN's Number is signed 16-bit
        move.l  %d0,(%a1)
        move.l  (%sp)+,%d2
        jsr     brain_post_settings         | saved as a SETTINGS edit is
        bsr     rmx_leds
9:      rts

| trig 1..16 -> its source bit (Bryan T's layout)
        .balign 2
rmx_trig_bit:
        .word   M_AB, M_CD, 0x4000, 0x8000          | AB, CD, MAIN, CUE
        .word   M_A, M_B, M_C, M_D                  | A, B, C, D
        .word   0x0040, 0x0080, 0x0100, 0x0200      | T1..T4
        .word   0x0400, 0x0800, 0x1000, 0x2000      | T5..T8

| ---- LEDs -------------------------------------------------------------------

| The row on the trig LEDs: trig n's first LED (id 2n) lit when its source
| is selected; both of its LEDs at full level, not blinking.
rmx_leds:
        lea     -16(%sp),%sp
        movem.l %d2-%d4/%a2,(%sp)
        bsr     rmx_cur_ptr
        move.l  %d0,%a0
        move.l  (%a0),%d4                   | d4 = the mask
        lea     rmx_trig_bit,%a2
        moveq   #0,%d2                      | d2 = the trig
1:      move.l  %d2,%d3
        add.l   %d3,%d3                     | d3 = its first LED id
        move.l  %d3,-(%sp)
        jsr     (LED_NOBLINK).l
        addq.l  #4,%sp
        move.l  %d3,%d0
        addq.l  #1,%d0
        move.l  %d0,-(%sp)
        jsr     (LED_NOBLINK).l
        addq.l  #4,%sp
        pea     15
        move.l  %d3,-(%sp)
        jsr     (LED_LEVEL).l
        addq.l  #8,%sp
        pea     15
        move.l  %d3,%d0
        addq.l  #1,%d0
        move.l  %d0,-(%sp)
        jsr     (LED_LEVEL).l
        addq.l  #8,%sp
        clr.l   -(%sp)                      | the second LED off
        move.l  %d3,%d0
        addq.l  #1,%d0
        move.l  %d0,-(%sp)
        jsr     (SET_LED).l
        addq.l  #8,%sp
        moveq   #0,%d0
        move.w  (%a2,%d2.l*2),%d0
        and.l   %d4,%d0
        beq.s   2f
        move.l  #0x7fffffff,%d0             | lit until the editor turns it off
2:      move.l  %d0,-(%sp)
        move.l  %d3,-(%sp)
        jsr     (SET_LED).l
        addq.l  #8,%sp
        addq.l  #1,%d2
        moveq   #16,%d0
        cmp.l   %d0,%d2
        blt     1b
        movem.l (%sp),%d2-%d4/%a2
        lea     16(%sp),%sp
        rts

| Every trig LED off; stock's refresh redraws its own on its next pass.
rmx_leds_off:
        move.l  %d2,-(%sp)
        moveq   #0,%d2
1:      clr.l   -(%sp)
        move.l  %d2,-(%sp)
        jsr     (SET_LED).l
        addq.l  #8,%sp
        addq.l  #1,%d2
        moveq   #32,%d0
        cmp.l   %d0,%d2
        blt.s   1b
        move.l  (%sp)+,%d2
        rts

| 0x40043fdc, a "jmp" detour: stock's trig-LED refresh, (track). Open: the
| row, and the stock pass skipped. Closed: the displaced `lea -68(sp),sp;
| movem.l d2-d6/a2-a5,(sp)` and on.
        .global rmx_on_leds
rmx_on_leds:
        tst.l   rmx_editing
        beq.s   1f
        bra     rmx_leds
1:      lea     -68(%sp),%sp
        movem.l %d2-%d6/%a2-%a5,(%sp)
        jmp     (LEDS_CONT).l

| ---- the screen -------------------------------------------------------------

| 0x4002f2f8, a "jmp" detour: the setup window's redraw. Open: the matrix.
| Closed: the displaced `link fp,#-104; movem.l d2-d7/a2-a5,(sp)` and on.
        .global rmx_on_draw
rmx_on_draw:
        tst.l   rmx_editing
        bne     rmx_draw
        link    %fp,#-104
        movem.l %d2-%d7/%a2-%a5,(%sp)
        jmp     (DRAW_CONT).l

| The editor's window: title "REC BUF n"; a header of the sixteen sources in
| trig order; under it a row per recorder (buffer 1 at the top), a box per
| source, filled when selected; the active track's row inverted (8 rows fit
| 5 px apart, too close for row labels). y runs up from the bottom of the
| surface.
rmx_draw:
        link    %fp,#-32
        lea     -40(%sp),%sp
        movem.l %d2-%d7/%a2-%a5,(%sp)
        move.l  rmx_win,%a3
        tst.l   %a3
        beq     9f
        moveq   #0,%d0
        move.b  (CUR_TRACK).l,%d0
        addq.l  #1,%d0
        move.l  %d0,-(%sp)
        pea     rmx_title_fmt
        pea     -32(%fp)
        jsr     (SPRINTF).l
        lea     12(%sp),%sp
        clr.l   -(%sp)
        pea     -32(%fp)
        move.l  %a3,-(%sp)
        jsr     (SET_TITLE).l
        lea     12(%sp),%sp
        lea     36(%a3),%a4                 | a4 = the surface
        move.l  %a4,-(%sp)
        jsr     (CLEAR_BODY).l
        addq.l  #4,%sp
        move.l  4(%a4),%d0                  | the surface's height (64)
        sub.l   #HDR_FROM_TOP,%d0
        move.l  %d0,%d6                     | d6 = the header's baseline
| the header: a label over each column
        lea     rmx_hdr,%a5
        moveq   #0,%d2
1:      lea     rmx_hdr_xs,%a0
        moveq   #0,%d0
        move.b  (%a0,%d2.l),%d0             | d0 = the label's x
        move.l  (%a5)+,%a1
        move.l  %a1,-(%sp)
        pea     -1
        move.l  %d6,-(%sp)
        move.l  %d0,-(%sp)
        move.l  %a4,-(%sp)
        pea     FONT
        jsr     (DRAWSTR).l
        lea     24(%sp),%sp
        addq.l  #1,%d2
        moveq   #16,%d0
        cmp.l   %d0,%d2
        blt.s   1b
| the rows
        lea     rmx_mask_ptr,%a2
        moveq   #0,%d3                      | d3 = the recorder
2:      move.l  %d6,%d5
        sub.l   #ROW1_BELOW_HDR,%d5
        move.l  %d3,%d0
        mulu.w  #ROW_PITCH,%d0
        sub.l   %d0,%d5                     | d5 = the row's box bottom
3:      move.l  (%a2,%d3.l*4),%a0
        move.l  (%a0),%d7                   | d7 = the row's mask
        lea     rmx_trig_bit,%a5
        moveq   #0,%d2                      | d2 = the column
4:      bsr     rmx_col_x
        move.l  %d0,%d4                     | d4 = the box's left
        pea     1                           | the box, filled
        move.l  %d5,%d0
        add.l   #BOX-1,%d0
        move.l  %d0,-(%sp)
        move.l  %d4,%d0
        add.l   #BOX-1,%d0
        move.l  %d0,-(%sp)
        move.l  %d5,-(%sp)
        move.l  %d4,-(%sp)
        move.l  %a4,-(%sp)
        jsr     (INVERT).l
        lea     24(%sp),%sp
        moveq   #0,%d0
        move.w  (%a5,%d2.l*2),%d0
        and.l   %d7,%d0
        bne.s   5f
        clr.l   -(%sp)                      | not selected: its inside cleared
        move.l  %d5,%d0
        add.l   #BOX-2,%d0
        move.l  %d0,-(%sp)
        move.l  %d4,%d0
        add.l   #BOX-2,%d0
        move.l  %d0,-(%sp)
        move.l  %d5,%d0
        addq.l  #1,%d0
        move.l  %d0,-(%sp)
        move.l  %d4,%d0
        addq.l  #1,%d0
        move.l  %d0,-(%sp)
        move.l  %a4,-(%sp)
        jsr     (INVERT).l
        lea     24(%sp),%sp
5:      addq.l  #1,%d2
        moveq   #16,%d0
        cmp.l   %d0,%d2
        blt     4b
        moveq   #0,%d0
        move.b  (CUR_TRACK).l,%d0
        cmp.l   %d3,%d0
        bne.s   6f
        bsr     rmx_mark                    | the active track's row: its number at
                                            | the left, a pointer at the right
6:      addq.l  #1,%d3
        moveq   #8,%d0
        cmp.l   %d0,%d3
        blt     2b
9:      movem.l (%sp),%d2-%d7/%a2-%a5
        lea     40(%sp),%sp
        unlk    %fp
        rts

| The active row's marks, leaving the boxes alone: the buffer's number in the
| left margin and a pointer at the right. a4 = surface, d3 = row, d5 = its
| box bottom. Clobbers d0-d2, d4, a0, a1, a5.
rmx_mark:
        move.l  %d3,%d0
        add.l   #'1',%d0
        lsl.l   #8,%d0                      | "n\0" in a word on the stack
        move.w  %d0,-(%sp)
        move.l  %sp,%a1
        subq.l  #2,%sp                      | keep the stack long-aligned
        move.l  %a1,-(%sp)
        pea     -1
        move.l  %d5,%d0
        add.l   #NUM_DY,%d0
        move.l  %d0,-(%sp)
        pea     NUM_X
        move.l  %a4,-(%sp)
        pea     FONT
        jsr     (DRAWSTR).l
        lea     28(%sp),%sp
        lea     rmx_arrow,%a5               | the pointer: three columns
        moveq   #3,%d4
1:      pea     1
        move.b  3(%a5),%d0
        ext.w   %d0
        ext.l   %d0
        add.l   %d5,%d0
        move.l  %d0,-(%sp)                  | y1
        moveq   #0,%d0
        move.b  2(%a5),%d0
        move.l  %d0,-(%sp)                  | x1
        move.b  1(%a5),%d0
        ext.w   %d0
        ext.l   %d0
        add.l   %d5,%d0
        move.l  %d0,-(%sp)                  | y0
        moveq   #0,%d0
        move.b  (%a5),%d0
        move.l  %d0,-(%sp)                  | x0
        move.l  %a4,-(%sp)
        jsr     (INVERT).l
        lea     24(%sp),%sp
        addq.l  #4,%a5
        subq.l  #1,%d4
        bgt.s   1b
        rts

| x0, dy0, x1, dy1 (dy from the row's box bottom): a left-pointing arrowhead
| 6 px tall, its outer column in the 1-px gaps between rows
rmx_arrow:
        .byte   120, 1, 120, 2
        .byte   121, 0, 121, 3
        .byte   122, -1, 122, 4
        .balign 2

| d0 = the left x of column d2's box (rmx_col_xs).
rmx_col_x:
        lea     rmx_col_xs,%a0
        moveq   #0,%d0
        move.b  (%a0,%d2.l),%d0
        rts

| box x per column: AB and CD wide enough for their two-letter labels, a gap
| after the stereo sources and after the inputs
rmx_col_xs:
        .byte   10, 21, 30, 36,  45, 51, 57, 63,  72, 78, 84, 90, 96, 102, 108, 114
| header x per column (a label's left; AB and CD centred over their boxes)
rmx_hdr_xs:
        .byte    7, 18, 30, 36,  45, 51, 57, 63,  72, 78, 84, 90, 96, 102, 108, 114
        .balign 2

| the grid (checked against the screen under the port)
        .equ    HDR_FROM_TOP,   17
        .equ    ROW1_BELOW_HDR, 7
        .equ    ROW_PITCH,      5
        .equ    BOX,            4
        .equ    NUM_X,          4           | the active row's number
        .equ    NUM_DY,         0

rmx_title_fmt:
        .asciz  "REC BUF %d"
        .balign 4
rmx_hdr:
        .long   h_ab, h_cd, h_m, h_q, h_a, h_b, h_c, h_d
        .long   h_1, h_2, h_3, h_4, h_5, h_6, h_7, h_8
h_ab:   .asciz  "AB"
h_cd:   .asciz  "CD"
h_m:    .asciz  "M"
h_q:    .asciz  "Q"
h_a:    .asciz  "A"
h_b:    .asciz  "B"
h_c:    .asciz  "C"
h_d:    .asciz  "D"
h_1:    .asciz  "1"
h_2:    .asciz  "2"
h_3:    .asciz  "3"
h_4:    .asciz  "4"
h_5:    .asciz  "5"
h_6:    .asciz  "6"
h_7:    .asciz  "7"
h_8:    .asciz  "8"

| ---- the editor's key layer ---------------------------------------------------

        .balign 4
| {next, keys, encoders, 0, marker}; LAYER_ADD sets the marker.
rmx_layer:
        .long   0, rmx_keys, rmx_encs, 0, 0

| key records, 26 bytes: code, 0, press, release, 0, sub-map, claim, 0, 0
        .macro  key code, press
        .byte   \code, 0
        .long   \press, 0, 0, 0, 0
        .word   0, 0
        .endm
        .balign 2
rmx_keys:
        .irp    t, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        key     \t, rmx_trig
        .endr
        key     0x32, rmx_key_close         | NO
        key     0x3c, rmx_key_close         | knob E's push
        .byte   0xff, 0

| encoder records, 22 bytes: knob, 0, handler 0 (swallowed), 0...
        .macro  enc n
        .byte   \n, 0
        .long   0, 0, 0, 0, 0
        .endm
        .balign 2
rmx_encs:
        .irp    n, 0,1,2,3,4,5
        enc     \n
        .endr
        .byte   0xff, 0

        .data
        .balign 4
rmx_editing:
        .long   0
rmx_win:
        .long   0
