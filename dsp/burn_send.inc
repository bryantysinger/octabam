; ---- RIG BURN (BURN=1 with SPEC=1, 13 Sep 2026): the cycle burn on SEND --
; SEND is on every core and its page has one knob, so a burn here sweeps
; EITHER core's ceiling with the shipping servers untouched -- the reverb's
; own burn blocks (dsp/burn_block{1,2}.inc) are 18 words that payload A has
; not got, and they only ever burned the reverb's core. Placed at the top of
; proc, right after the call-flag stash: `a` is saved, nothing else is live.
;
; ⚠️ FX2 ONLY, tested PER CALL. Id 0 is aliased to SEND, so on the unit this
; proc also runs on every FX1 slot set to NONE, with r6 on that slot's page
; -- whose bytes are whatever the last effect left there. The first cut
; burned on those too and hung the sequencer on step 1 with every effect
; turned off (85B, 13 Sep 2026; the emulator never instantiates an FX1-NONE
; slot, so it could not show it). The stations' idiom: X:$213 -> the
; instance base; >= 0x4000 is an FX2 slot. Tested here, not at init: an
; alias instance never ran init, so a flag slot would be garbage.
;
; burn = 24 * BURN cycles/sample: (8 * BURN * n7) iterations of a THREE-word
; body over n7 samples (the reverb's block used four nops for 32/step).
; The alignment is the reverb block's: mpy is fractional, so n7 (an integer
; in x0) times the raw knob word p1<<16 (y1) leaves n7*p1*2^17 in A[47:0],
; and A1 = A[47:24] shifted by #$a is 8*p1*n7 exactly (max 16256).
; THE ZERO GUARD IS LOAD-BEARING: DO with a count of 0 loops 65536 times.
; asl sets Z, so no tst. `mpy x0,y1` is the encodable, signed pair.
        move    x:>$213,r4              ; the instance base pointer (m4 is
        move    x:(r4),a                ; the global linear invariant)
        add     #>$ffc000,a             ; base - 0x4000
        bmi     sbnoburn                ; < 0x4000: an FX1 slot, no burn
        move    x:(r6+$c),a             ; BURN: page-2 slot 6, $c's knob field
        and     #>$7f0000,a             ; (bits 16-23; page-1 slot 1's word is
        move    a1,y1                   ; not the stored byte -- see build_bus)
        move    n7,x0                   ; frames on THIS call
        mpy     x0,y1,a
        asl     #$a,a,a                 ; A1 = 8 * p1 * n7; Z if either is 0
        beq     sbnoburn
        do      a1,>sbend               ; a1, not a: raw, no limiting
        nop
        nop
        nop
sbend:
sbnoburn:
