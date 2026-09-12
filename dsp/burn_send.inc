; ---- RIG BURN (BURN=1 with SPEC=1, 13 Sep 2026): the cycle burn on SEND --
; SEND is on every core and its page has one knob, so a burn here sweeps
; EITHER core's ceiling with the shipping servers untouched -- the reverb's
; own burn blocks (dsp/burn_block{1,2}.inc) are 18 words that payload A has
; not got, and they only ever burned the reverb's core. Placed at the top of
; proc, right after the call-flag stash: `a` is saved, nothing else is live.
;
; burn = 24 * p1 cycles/sample: (8 * p1 * n7) iterations of a THREE-word
; body over n7 samples (the reverb's block used four nops for 32/step; three
; is the most 13 words leave room for, and it is still clear of the one- and
; two-word DO cases whose cycle count is not obviously the word count).
;
; The alignment is the reverb block's: mpy is fractional, so n7 (an integer
; in x0) times the raw knob word p1<<16 (y1) leaves n7*p1*2^17 in A[47:0],
; and A1 = A[47:24] shifted by #$a is 8*p1*n7 exactly (max 16256).
;
; THE ZERO GUARD IS LOAD-BEARING: DO with a count of 0 loops 65536 times and
; hangs the instrument on the knob's safe position. asl sets Z, so no tst.
; `mpy x0,y1` is the encodable, signed pair (x0*y0 assembles as mpysu).
        move    x:(r6+$1),y1            ; p1 = BURN, the raw value<<16 word
        move    n7,x0                   ; frames on THIS call
        mpy     x0,y1,a
        asl     #$a,a,a                 ; A1 = 8 * p1 * n7; Z if either is 0
        beq     sbnoburn
        move    a1,x0                   ; a1, not a: raw, no limiting
        do      x0,>sbend
        nop
        nop
        nop
sbend:
sbnoburn:
