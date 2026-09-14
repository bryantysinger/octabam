; ---------------------------------------------------------------------------
; BusDelay: a two-line ping-pong delay with feedback tone-shaped by a one-pole
; low-pass inside the loop, and three engines on the same lines -- CLEAN,
; GRAIN (four unity-rate grain readers per line, one continuous pitch) and
; REVERSE (the two lines as one 32K mono ring, segments played backwards) --
; with tape wow, a sticky tempo snap on TIME and a freeze hold in every mode.
; CYCLES_FORWARD_BRANCHES -- the REVERSE skips of the R line are forward
; branches the pricer admits.
;
; The buffer base is one hardcoded literal (Y:0x30000, 32768 words) that
; build_bus.py rewrites per payload with a blanket text replace over the whole
; source, comments included, and censuses; shared-window addresses elsewhere
; in this file are offsets from a register-held base. The lines are plain
; circular buffers wrapped by hand (m1/m2 stay linear): the read address is
; base + ((wr - TIME) & mask) and the post-write pointer folds back the same
; way; both bases are 0x4000-aligned so the base falls out of the mask.
;   LineL   base+0x0000 .. base+0x3fff   16384 words (max ~371 ms)
;   LineR   base+0x4000 .. base+0x7fff   16384 words
;
; Input enters LineL, and LineR scaled by 1-PING; PING is a continuous 2x2
; crossfeed on the feedback path:
;        fbIntoL = fL*(1-PING) + fR*PING
;        fbIntoR = fR*(1-PING) + fL*PING
;        LineL[write] = x_in + fbIntoL*FDBK
;        LineR[write] = x_in*(1-PING) + fbIntoR*FDBK
; The loop gain per line is a convex combination of fL/fR scaled by FDBK, so
; stability does not depend on PING. (Summing the input into both lines
; unscaled makes the two state equations identical for a mono source, and
; PING does nothing.)
;
; Every proc() call runs the position-0 rotation-flip-and-clear housekeeping
; modules/send/send_client.asm describes (copied byte for byte: a divergent
; copy desyncs the bus silently), sums the shared DELAY accumulator into its
; input, multiplies by the auto-gain 1/sqrt(N) and writes its stage output
; to the chain buffer for the reverb and the return. The host track prints
; the stage output (in*(1-MIX) + wet*MIX); its own audio reaches the engine
; only through AUX.
;
; State in the per-instance r7 block. The numbers below are raw slots; the
; code from `bus_mine:` to `dry:` spells them rebased -- r7 is moved $49
; into the block there so every access is the one-word displaced move, and
; slot NN reads as x:(r7+(NN-$49)): $14 is x:(r7-$35), $88 is x:(r7+$3f).
;   r7+$14              call flag stash (proc entry accumulator)
;   r7+$15/$16/$17      per-sample scratch (age / phase then g^2 / t0 then
;                       tap); $15 doubles as the warm-up count stash
;   r7+$18              grain PRNG state, 23-bit xorshift (persistent, seeded
;                       nonzero at warm-up)
;   r7+$19..$1f         GRAIN per-sample parks: window, frac, t0, read phase,
;                       s, wet L, wet R
;   r7+$21..$23         per-sample scratch (PRNG candidate, parked age)
;   r7+$24/$25          shifted OUTPUT tap L / R (per sample; kept apart from
;                       the loop's taps so the shift never re-enters feedback)
;   r7+$26              FREEZE flag (per block; nonzero = hold the lines)
;   r7+$27/$28          wow / flutter LFO phase (persistent, masked)
;   r7+$29..$2c         wow per-sample scratch (offset, phase, t0, fraction)
;   r7+$2d/$2e          wow depth / flutter depth (per block)
;   r7+$2f/$30          per-sample scratch (the parked write value, clipped)
;   r7+$31              LineL base
;   r7+$32              GRAIN base age, Q11.12 (persistent, masked on load
;                       and save); each grain is a fixed quarter cycle off it
;   r7+$33              SHIFTED-OUTPUT flag (per block): the wet comes from
;                       $24/$25 (GRAIN)
;   r7+$34..$37         GRAIN latched scatter s0..s3 (persistent, latched at
;                       each grain's own wrap; cleared by the warm-up)
;   r7+$38/$39/$3a      GRAIN mask G-1, G/4 (grain-to-grain phase offset),
;                       window multiplier 2^(23-k) (per block, from SIZE)
;   r7+$3b              GRAIN read distance base lag + G + 1 (per block; lag
;                       capped so lag + scatter + G stays inside the line)
;   r7+$3c/$3d          GRAIN density and makeup coefficient (per block)
;   r7+$40..$4b         GRAIN line-L records: s, w, acc x 4 grains
;   r7+$4c..$57         GRAIN line-R records
;   r7+$58/$59          this sample's scatter / window-multiplier candidates
;   r7+$5d              GRAIN phase cursor
;   r7+$56..$5b         REVERSE per-sample scratch (mode-exclusive with GRAIN)
;   r7+$5e              REVERSE segment phase, 23-bit (persistent, masked on
;                       load and save); one phase for both lines and heads
;   r7+$5f              SIZE select index, raw 0..3 (per block)
;   r7+$60/$61          REVERSE segment length S / phase step 2^23/S
;   r7+$62              REVERSE lag floor (per block)
;   r7+$63/$64          this call's DELAY ACC read / DELAY WET write address
;   r7+$65..$67         split-aware bus bookkeeping (shared mechanism)
;   r7+$68              LineR base = LineL base + 0x4000 (per block)
;   r7+$69              MODE, MSB-aligned select (per block; 0 = CLEAN,
;                       1 = GRAIN, 2 = REVERSE; anything else = CLEAN)
;   r7+$6a              this block's MIDI note for GRAIN (0 = none)
;   r7+$6b              the L ring's mask: $3fff, or $7fff in REVERSE
;   r7+$6c              skipR: 1 in REVERSE (the R line's read and write are
;                       skipped per sample; the output is mono to both)
;   r7+$6e/$6f          scratch: x_in*(1-MIX), stage output L (per sample)
;   r7+$70/$71          LineL/LineR write-pointer phase (persistent, masked
;                       on load and save: garbage with bit 23 set saturates
;                       the AGU and hangs the bus)
;   r7+$72/$73/$74/$75  TONE coefficient, FDBK coefficient, PING, TIME (per block)
;   r7+$76              IN, pinned to 0 (its arithmetic stays in the loop)
;   r7+$77/$78          TONE filter state, line L / R (persistent)
;   r7+$79/$7a          scratch: dL/dR, raw taps (per sample)
;   r7+$7b/$7c          scratch: fL/fR, damped taps == this sample's wet
;   r7+$7d              scratch: x_in, own dry mono + bus (per sample)
;   r7+$7e/$81          scratch: fbIntoL/fbIntoR (per sample)
;   r7+$7f              bus auto-gain 1/sqrt(N) (per block; read per sample)
;   r7+$80              1 - PING (per block)
;   r7+$82              warm-up tagged counter
;   r7+$83              DRIVE amount d (pinned to 0)
;   r7+$84              this call's CHAIN write address ($901 + rotation +
;                       frame offset; advances per sample)
;   r7+$85/$87          MIX / 1-MIX (per block)
;   r7+$86              this block's resolved write offset (0/16/32/48);
;                       every bus address derives from it
;   r7+$88              last-seen rotation (the gated housekeeping block's)
;   $84+ hangs the unit on a raw r7; nothing here is stored above $88.
;
; Parameters (a knob arrives as value<<16, value 0..127):
;   p0 AUX   -> this host's own dry send into the aux (headroomed, summed
;               before the auto-gain, counted as a client while nonzero)
;   p1 TIME  -> delay length, 64 .. 16320 samples (~1.5 .. 370 ms), a free
;               dial that sticky-snaps to a tempo division (1/32T .. 1/4 of
;               the tempo the ColdFire cave publishes at r6+$6/$7), holds it
;               through tempo changes and lets go when the knob moves; the
;               STICKY SNAP block in proc
;   p2 FDBK  -> feedback gain, 0 .. ~0.87 (FDBK=0 is a single echo)
;   p3 TONE  -> one-pole coefficient, 0.125 (dark) .. 0.99 (bright)
;   p4 PING  -> crossfeed, 0 (centred) .. ~0.99 (full ping-pong), Q1.23
;   p5 MIX   -> the stage crossfade
;   p6 MODE  -> page-2 slot 6 KNOB field (r6+$c bits 16-23)
;   p7 MDEP  -> wow depth (GRAIN: scatter), slot 7 companion (r6+$c bits 8-15)
;   p8 MRAT  -> wow rate, 64 = 1x (GRAIN: density)
;   p9 SIZE  -> slot 9 companion (r6+$d low bits): GRAIN grain length and
;               REVERSE segment, one select for both
;   p10 PTCH -> slot 10 KNOB field (r6+$e bits 16-23): GRAIN pitch, +-2 oct;
;               a held MIDI note (r6+$9, latched) overrides
;   p11 FRZE -> slot 11 companion (r6+$e low bits), count 2
; ---------------------------------------------------------------------------

init:
; Hardcoded base, no per-instance stash needed -- literal is identical for
; every instance, same reasoning as modules/busverb/reverb_server.asm's init.
; ---- seed the tracked rotation, so a cold boot cannot start out of step ---
; ⚠️ THE TRACKING CANNOT SELF-CORRECT A BAD START, and the commit that added it
; claimed otherwise. "This client legitimately read PRE-FLIP" and "this client
; is stuck one step AHEAD" give an identical comparison result, every block,
; forever -- no observation separates them, so a client that boots one step
; ahead stays there. Harmless when written; NOT harmless once the clear moved
; one block ahead, because a client stuck one step ahead then writes precisely
; the buffer core 0 is clearing, and every core-1 sender is wiped. That was the
; metallic on every power cycle of R25, and why re-selecting the effect cured
; it: the instance misses blocks during the switch, falls BEHIND, and snaps.
; If it cannot self-correct it must begin correct. init runs on instantiation
; -- exactly what re-selecting does -- so seeding here makes a cold boot
; deterministic. The shared word may advance one step before the first proc;
; that direction DOES snap, so it is safe.
; build_bus.py emits a body here for PAYLOAD B ONLY -- payload A recomputes the
; offset from the shared word every block and has nothing to seed.
; ROTINIT
        rts

proc:
; ---- BOTH calls are audio -------------------------------------------------
; Same dispatcher shape as every other effect in this project -- see
; dsp/reverb89.asm's proc: comment for the full mechanism. Everything below
; re-derives from r7 state per call, so the two sub-calls of a split block
; are sample-continuous by construction.
        move    a,x:(r7+$14)            ; call flag: $010000 = the a=1 call
; build_bus.py substitutes a host-slot gate at the marker below, for a
; remix that HIDES this engine (schema.Remix.hidden). A hidden engine is hosted by
; the project's stamp rather than by the chooser, so it should run on its
; host track and nowhere else: dispatch is per id and shared by every track,
; so an old part naming this id on another track would otherwise get a
; SECOND instance sharing this one's hardcoded Y base. The gate is r7 ==
; 0x6200, the bank's first FX2 state block (measured, docs/firmware/DSP.md "The
; allocator's instance model"), which is the same condition the position-0
; housekeeping election below already uses -- so a guarded instance is never
; a housekeeper that has gone dry, nor a wet engine that skips the
; election. (Worded around the phrase build_bus.py censuses for: it
; greps the SOURCE for the payload-gate marker, comments included, so
; writing that phrase here reported the plain `bus` image's payload A
; as gated out -- caught by refhash, and the same family as the
; base-literal census CLAUDE.md warns about, which refused the build
; when this very comment first tried to name it.)
; Inert in a normal build: it is a comment, and local renders (which run at
; -r7 4, the bank's SECOND slot) are unaffected unless a remix asks for it.
; HOSTGUARD

; ---- BUS.md: split-aware frame offset + position-0 election --------------
; Verbatim from modules/send/send_client.asm / modules/busverb/reverb_server.asm (BUS.md Known
; limitations: this copy must stay byte-identical across all three files).
        clr     a
        move    a,x:(r7+$67)            ; default: offset 0 (first call)
        move    x:(r7+$14),a
        tst     a
        bne     bus_a1
        move    #>$1,a
        move    a,x:(r7+$65)            ; "a=0 ran this block"
        move    n7,a
        and     #>$f,a                  ; same mask on the way in
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$66)            ; stash split for the matching a=1
        bra     bus_off_done
bus_a1:
; COLD-BOOT SAFETY. These slots hold boot garbage the first time an instance
; runs, and x:(r7+$67) feeds straight into r1/r2 as a Y pointer below -- an
; unmasked garbage value there makes the per-sample loop write through a wild
; address, which hangs the DSP. Reproduced on hardware: selecting SEND on any
; track from a clean boot froze the unit. Same class as DSP.md's masked-garbage
; AGU saturation, so the same discipline -- mask AND A2-clean before use.
        move    x:(r7+$65),a
        and     #>$ff,a                 ; flag field only
        move    a1,x0
        move    x0,a                    ; A2-clean before the compare
        move    #>$1,x0
        cmp     x0,a                    ; EXACTLY 1, not merely nonzero --
        bne     bus_off_done            ; "nonzero" accepts almost any garbage
        clr     a
        move    a,x:(r7+$65)            ; consume the flag
        move    x:(r7+$66),a
        and     #>$f,a                  ; a split point is 0..15 by
        move    a1,x0                   ; construction, so this cannot narrow a
        move    x0,a                    ; legitimate value -- it only makes
        move    a,x:(r7+$67)            ; garbage harmless
bus_off_done:

; ---- position-0 housekeeping: flip the shared bus rotation, clear the new
; write-target ACC buffers. Gated on r7==0x6200 AND offset==0 -- copied from
; modules/send/send_client.asm / modules/busverb/reverb_server.asm, must stay identical.
; Housekeeping is normally done by position 0 (r7 == 0x6200, the bank's first
; FX2 call). That alone breaks the moment the first track's FX2 is NONE: our
; code never runs there, so nobody flips the rotation or clears the
; accumulators, and the bus saturates. NONE became selectable with the task-11
; menu, so this is reachable in ordinary use.
;
; Self-healing election instead. Position 0 still housekeeps whenever it runs.
; Any other instance takes over if it sees that the rotation has NOT changed
; since the last time it ran -- which can only mean nobody housekept in
; between. Costs one r7 word (the rotation this instance last saw) and no new
; global signal, so it needs nothing the bus does not already have.
;
; Gated on the split offset FIRST: only a block's first call may housekeep, so
; a split block's second call can never flip a second time -- the same trap
; the original position-0 code was written around.
; XBUS_GATE -- build_bus.py substitutes a payload gate here when XBUS=1.
; A shared-memory bus is housekept by ONE core only: both cores number their
; own instances from zero, so each core's position 0 believes it is the
; housekeeper and they would flip the shared rotation TWICE a block, cancelling
; out and silently desyncing the bus -- the same trap the split-call gate
; below was written around, one level up. Payload B is sent straight to
; bus_notfirst, so it still finds this block's write targets but never elects.
; Inert in a normal build: it is a comment.
        move    x:(r7+$67),a
        tst     a
        bne     bus_notfirst                ; not this block's first call
        move    r7,a
        move    #>$6200,x0
        cmp     x0,a
        beq     bus_dohk                ; position 0: always the housekeeper
        move    y:>$900,a
        and     #>$30,a
        move    a1,x0
        move    x0,a                    ; offset now, A2-clean
        move    x:(r7+$88),x0
        cmp     x0,a
        bne     bus_seen                ; it moved: someone else housekept
bus_dohk:                               ; nobody did -- take over this block

; y:>$900 holds the WRITE OFFSET (0/16/32/48), not the bare buffer index --
; see the layout comment in modules/send/send_client.asm. FOUR buffers, so the rotation
; is +16 mod 4 and the mask that does the modulo sanitises boot garbage too.
; No `asl #$4` follows: the value is already scaled.
        move    y:>$900,a
        add     #>$10,a
        and     #>$30,a
        move    a,y:>$900               ; the new CURRENT rotation
        add     #>$10,a                 ; one further on: the NEXT block's
        and     #>$30,a                 ; write target, idle right now
        move    a,x0                    ; bases for the clear AND the count

        move    #>$961,b                ; ONE BUS (6 Sep 2026): the AUX
        add     x0,b                    ; accumulator, the only one left
        move    b,r2                    ; r2 = AUX ACC[new] base
        move    #>$ffffff,m2
        clr     a
        move    #>16,y0
        do      y0,>bus_zclr
        move    a,y:(r2)+
bus_zclr:
        nop
; ---- release both server-role locks for this block (BUS.md hardware test 3)
; a is still 0 from the clear loop above. Whichever of the three effects is
; position 0 does this, so the locks are freed exactly once per block and
; re-claimed below in dispatch order.
        move    a,y:>$9c1               ; DELAY SERVER role owner
        move    a,y:>$9c2               ; REVERB SERVER role owner
        move    x0,a                    ; the SAME buffer the clear loop just
        asr     #$4,a,a                 ; zeroed: count and accumulator move
        move    #>$9c7,x0               ; together (0..3); the AUX count
        add     x0,a
        move    a,r3
        move    #>$ffffff,m3
        clr     a
        move    a,y:(r3)                ; AUX count = 0
bus_seen:
        move    y:>$900,a               ; remember this block's offset so next
        and     #>$30,a                 ; block we can tell whether anybody
                                        ; else housekept in between
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$88)
bus_notfirst:
; ---- resolve THIS BLOCK'S WRITE OFFSET, ONCE, into r7+$86 ---------------
; See the long note in modules/send/send_client.asm: every client used to read y:>$900
; at its own dispatch time, which is not a stable value on payload B because
; core 0 owns the flip. This server is on payload B, so it is exposed.
; build_bus.py substitutes a per-payload body here; both leave the offset in
; r7+$86, and every site downstream reads that instead of the shared word.
; ROTLATCH

; ---- server-role lock: only ONE DELAY SERVER may run per bank -----------------
; Both servers use a FIXED, hardcoded Y base identical for every instance, so
; two of the same role would share one set of buffers and drive each other's
; feedback path -- measured on hardware as a solid, unchanging tone (BUS.md's
; hardware test 3). The lock is released once per block by whichever effect is
; position 0 (above) and claimed here in dispatch order: the first instance to
; arrive owns the role for that block, any duplicate rts's without touching
; the audio buffer at all, which is an exact dry passthrough.
;
; Keyed on r7 (this instance's own state block), so a split block's two calls
; both match the same owner and the second is not mistaken for a duplicate.
        move    y:>$9c1,a
        move    a1,x0
        move    x0,a                    ; A2-clean before the compare
        tst     a
        beq     bus_claim               ; free: take it
        move    r7,x0
        cmp     x0,a
        beq     bus_mine                ; already ours (split block's 2nd call)
        rts                             ; a duplicate: pass audio through
bus_claim:
        move    r7,a
        move    a,y:>$9c1
bus_mine:
; ---- r7 REBASE (14 Sep 2026): from here to `dry:` r7 points $49 INTO the
; state block. The one-word displaced move reaches -64..63 and the block
; spans $14..$88, so with the raw r7 every slot from $40 up cost two words
; (222 sites, most of them per sample). Slot NN is written x:(r7+(NN-$49))
; from here on -- x:(r7-$35) is $14, x:(r7+$3f) is $88 -- and the header
; map and every comment keep the RAW numbers. Everything that compares or
; stores r7 ITSELF (the position-0 test, the role lock, the ROTLATCH /
; ROTINIT / HOSTGUARD bodies the build substitutes) runs ABOVE this point
; on the raw value; the duplicate-server rts above never reaches it; the
; GRAIN record bases below derive from the rebased value; `dry:` puts the
; raw block back before the rts. Costs 8 words a call, pays ~190.
        move    r7,a
        add     #>$49,a
        move    a,r7                    ; r7 = state block + $49
        move    #>$fab1e0,n4            ; the P table -- rewritten by build_bus.py

; ---- this call's DELAY ACC read address and DELAY WET write address ------
; READ is the OTHER buffer from the current write rotation -- the one every
; SEND client (and our own dry sum, below) finished filling last block.
; WRITE uses the SAME rotation clients currently write into, for a future
; cross-bus reader (task 10), not consumed by anything yet.
; ⚠️ THE OFFSET COMES FROM r7+$86, NOT y:>$900. This server lives on payload B
; and cannot read the shared rotation at its own dispatch time -- core 0 flips
; it asynchronously, so a core-1 client whose window straddles the flip sees a
; different value on different blocks. The resolve block at bus_notfirst
; tracks a stable rotation for this core; see the long note there and
; docs/effects/XBUS.md step 3.
; The offset is already scaled by the 16-word buffer stride, so the write
; addresses need no shift at all. THE READ TARGET IS TWO BUFFERS
; BACK, `write + 32 & $30`. THIS IS THE LINE THE WHOLE RACE FIX IS FOR: with
; four buffers there is an idle block on each side of this read, so core 0's
; housekeeper can lead or lag core 1 by up to a full block and still never
; clear or write the words being read here. Two buffers had no such margin at
; any clear time, which is why the delay stuttered on track 1 and not track 4
; (hardware, 17 Aug 2026 -- dispatch position moved the read relative to the
; other core's flip).
        move    x:(r7+$3d),a
        move    a,x1                    ; x1 = write offset (0/16/32/48)
        add     #>$20,a                 ; two buffers on == two buffers back
        and     #>$30,a                 ; mod 4
        move    a,x0                    ; x0 = the read offset
        move    #>$961,a
        add     x0,a
        move    x:(r7+$1e),b            ; this call's split-aware frame offset
        add     b,a
        move    a,x:(r7+$1a)            ; this call's DELAY ACC read address
; ---- this call's DELAY WET write address: STEREO, FOUR DEEP (3 Sep 2026) --
; Read now, by a Character station in BUS mode -- the return on the master
; (docs/effects/BUS.md "The returns"), which is on the OTHER core -- so it takes the
; accumulators' four-buffer rotation and carries L and R (32 words a buffer,
; interleaved: the ping-pong image is the point of the delay). The base is
; the reverb's wet page plus $80 -- spelled as base + offset, NOT one literal,
; because only `$9xx` literals relocate under XBUS and a fused `$a5a` would
; stay core-private and silently miss the bus (the shared-window base rule).
        move    x1,a
        add     x1,a                    ; write offset x2 (0/32/64/96)
        add     b,a
        add     b,a                     ; + frame offset x2
        add     #>$9da,a
        add     #>$80,a                 ; the DELAY's page, after the reverb's
        move    a,x:(r7+$1b)            ; this call's WET write address (L; R at +1)

        move    x1,x0                   ; the full write offset, 0/16/32/48
        move    #>$901,a                ; the CHAIN buffer (one-aux rig, 7 Sep
        add     x0,a                    ; 2026): 4 x 16 mono words, the old
        add     b,a                     ; REVERB accumulator's home
        move    a,x:(r7+$3b)            ; this call's CHAIN write address

; ---- RETD: is a return live on the delay's wet? (clear-on-read stamp) -----
; The reverb's mechanism verbatim (modules/busverb/reverb_server.asm, RETV):
; a return station stamps y:$9d9 nonzero each block it returns this bus; the
; host prints its wet only while no stamp has arrived for 3 blocks, so with
; no return in the rig the delay still comes out of its host, bit-identically
; (print gain 1/2, doubled back in the guard bits). The grace counter and the
; print gain live in CORE-PRIVATE Y, two words past the MIDI note's (r7 is
; full, and the zero-padded spelling is what keeps the XBUS relocation off
; them, exactly as RATE's state -- build_bus.py's census counts these five
; refs, so this comment must not spell them).
        move    y:>$090b,a              ; blocks of grace left
        and     #>$3,a
        move    a1,x0
        move    x0,b                    ; A2-clean, boot garbage masked
        move    #>$1,x0
        sub     x0,b
        move    #$0,x0 
        tmi     x0,b                    ; floored at 0
        move    y:>$9d9,a               ; the stamp
        move    x0,y:>$9d9              ; clear-on-read (x0 is still 0)
        move    #>$3,x0
        tst     a
        tne     x0,b                    ; stamped this block: 3 blocks of grace
        move    b,y:>$090b
        move    #$40,a               ; print gain 1/2 (x2 on use = exactly 1)
        move    #$0,x0 
        tst     b
        tne     x0,a                    ; a return is live: print nothing
        move    a,y:>$090c              ; this block's host print gain
        move    x:(r7+$1e),b            ; the frame offset, back for what follows

        move    #>$ffffff,m5            ; r5 linear for the block (the

        move    x1,a                    ; the count belongs to the buffer this
        add     #>$20,a                 ; block READS, which is two buffers back
        and     #>$30,a                 ; mod 4
        asr     #$4,a,a                 ; scaled back down -- the counts are one
        move    #>$9c7,x0               ; word per buffer, not sixteen
        add     x0,a
        move    a,r5
        move    #>$1,x0                 ; the "one more client" increment
        clr     b                       ; b = 0 -- BEFORE the tst below
        move    x:(r6),a                ; AUX (slot 0): the host's own send
        and     #>$7f0000,a             ; knob field only
        tst     a
        tne     x0,b                    ; sending -> b = 1: we count ourselves
; ->DEL from the REVERB host (v8, 5 Sep 2026): BusVerb writes its ->DEL knob
; field to y:$941 every block -- a single-writer word, not a count RMW -- and
; it is one more client while nonzero. x0 is still the increment; the Tcc
; reads the tst with nothing between; a zero word leaves a = 0, which IS the
; right count. The warm-up below zeroes the word, so a rig with no reverb
; never counts boot garbage (and one block of it before the first warm-up
; is masked to 0..7 like everything else here).
        move    y:>$941,a
        tst     a
        tne     x0,a                    ; a = 1 if the reverb host is sending
        add     a,b                     ; ... one more client
        move    y:(r5),a                ; clients that wrote the buffer we read
        add     b,a                     ; ... plus ourselves, if sending
        and     #>$7,a                  ; masked: boot garbage cannot index wild
        add     #>$32,a                 ; + 50, the reciprocals' offset in the
        move    a1,n5                   ; P table -- a1 straight into n5, so
        move    n4,r5                   ; there is no store and no A2 to clean
        move    p:(r5+n5),a             ; 1/sqrt(N)
        move    a,x:(r7+$36)            ; this block's bus gain, used per sample

; ---- (the REVERB-client registration lived here until the one-aux rig,
; 7 Sep 2026: the delay is chain stage 1, its output reaches the reverb
; through the CHAIN buffer at unity, and it is not a client of anything.
; $9c3 is its liveness stamp now -- see dwarmdone.)

        move    #>$ffffff,m0            ; audio is read and written via r0
        move    #>$ffffff,m4            ; GRAIN walks its table with r4 -- the
                                        ; one free AGU pointer, held at the
                                        ; global linear invariant like the rest
        move    #>$30000,x0
        move    x0,x:(r7-$18)

; ---- warm-up: zero both lines and persistent state before running --------
; Same tagged-counter idiom as dsp/reverb89.asm/modules/busverb/reverb_server.asm, but a
; DIFFERENT TAG -- $2e0000, where reverb_server uses $2c0000. Both effects
; keep their counter in the same r7+$82 slot and the dispatcher does NOT clear
; the state block when a track's effect changes, so with a shared tag the
; incoming effect read the outgoing one's counter, saw a valid tag at full
; count, skipped warm-up entirely and ran on the other algorithm's leftover
; buffers. Measured on hardware as "the track will not switch between DELAY
; and REVERB SERVER" (BUS.md's hardware test 3). A distinct tag makes the
; other effect's counter fail the tag compare, restarting warm-up exactly as
; a cold start does. ($82 = $2e0000 | count.) Necessary here too: LineL and
; LineR hold boot garbage on
; first use, and this engine has real feedback, so uncleared garbage would
; recirculate rather than just play once and vanish. Sized for this file's
; 32768-word allocation: 128 words/block * 256 blocks = 32768 exactly.
        move    x:(r7+$39),a
        and     #>$fffe00,a             ; tag field -- AND cleans A1 only
        move    a1,x0
        move    x0,a                    ; A2-clean before the compare
        move    #$2e,x0  
        cmp     x0,a
        beq     dwarmtag
        clr     a                       ; garbage tag: warm-up starts at 0
        bra     dwarmrun
dwarmtag:
        move    x:(r7+$39),a
        and     #>$1ff,a
        move    a1,x0
        move    x0,a                    ; the count, A2-clean
        move    #>$100,x0
        cmp     x0,a
        bge     dwarmdone               ; warmed: run the delay
dwarmrun:
        move    a,x:(r7-$34)            ; count, for the save below
        asl     #$7,a,a                 ; count*128
        move    x:(r7-$18),x0
        add     x0,a
        move    a,r5                    ; base + count*128
        clr     b                       ; the zero source ...
        move    x:(r7-$18),x0           ; ... and both fill the AGU slot
        do      #128,>dwarmz
        move    b,y:(r5)+
dwarmz:
        move    b,x:(r7+$27)
        move    b,x:(r7+$28)
        move    b,x:(r7+$2e)
        move    b,x:(r7+$2f)
        move    b,y:>$941               ; the REVERB host's ->DEL flag (v8):
        move    r7,a
        sub     #>$22,a                 ; raw $27 (r7 is rebased by $49)
        move    a,r5
        do      #56,>dwarmc
        move    b,x:(r5)+
dwarmc:
; ---- THE GRAIN COUNT IS A BUILD-TIME LEVER (4 Sep 2026) -------------------
; Four grains per line is what this source assembles to. A remix that
; declares `grains=2` (schema.Remix) has build_bus.py substitute three
; things at the markers below, and nothing else changes:
;
;   ; GRAINCNT  the two rolled loops count 2 instead of 4
;   ; GRAINOFF  the grain-to-grain phase offset doubles, G/4 -> G/2, so two
;              grains still tile the cycle
;   ; GRAINMK   the makeup doubles, because FOUR triangle windows at quarter
;              offsets sum to exactly 2 while TWO at half offsets sum to
;              exactly 1 -- so the same coefficient would land 6 dB down
;
; WHY: cycles, not sound. The delay's core cannot carry four active stations
; beside a four-grain GRAIN (3,294 of 3,120 by the pricer); at two grains it
; fits. The cost is half the simultaneous grain voices, which is an ear
; decision, not a correctness one.
;
; ⚠️ THE HALF-OFFSET CASE HAS AN EXACT TEST and the quarter-offset one does
; not: two triangle windows a half period apart sum to exactly 1, so DC in
; must come back flat. That is the gate that caught Nimbus's double-rate
; window (CLAUDE.md, the a0 trap), and it is why the two-grain build is the
; better-checked of the two.
;
; GRAIN v5's PERSISTENT latches: eight scatters, eight window multipliers
; and eight read advances, each re-latched at its own grain's wrap. A garbage scatter subtracts
; straight into a read address and a garbage multiplier is a garbage window
; for one grain-life, so both start at 0 like the PITCH offsets do.
        move    b,y:>$090a              ; the latched MIDI note starts at NONE.
        move    #>$123456,a             ; PRNG seed: any nonzero word (xorshift
        move    a,x:(r7-$31)            ; is dead at 0), fixed for determinism
        move    x:(r7-$34),a            ; reload count
        add     #>$1,a
        add     #>$2e0000,a             ; tag | count+1
        move    a,x:(r7+$39)
        bra     dry                     ; output stays dry until warm
dwarmdone:
; ---- DELAY LIVE (one-aux rig, 7 Sep 2026): stamp y:$9c3 (the reverb's
; chain-live word) and y:$9c5 (the return station's) every block this engine
; really processes. Each is clear-on-read by its one reader. Not written
; during the warm-up above, so a warming delay is not live: the reverb reads
; the aux accumulator and the return falls through to the reverb.
        move    #>$1,x0
        move    x0,y:>$9c3
        move    x0,y:>$9c5
        move    x:(r7-$18),x0           ; LineL base

; ---- per-block: TIME, FDBK, TONE, PING, -VRB, IN, ... ---------------------
        move    x:(r6+$1),a             ; TIME: slot 1 (one-aux re-slot, 7 Sep 2026)
        and     #>$7f0000,a             ; knob field only
        asr     #$9,a,a                 ; value*128 (0..16256)
        move    #>64,x0
        add     x0,a                    ; floor 64 samples (~1.45 ms)
        move    a,x:(r7+$2c)            ; TIME, 64..16320 samples

        move    x:(r7+$2c),a            ; free-running TIME, from the knob
        move    a,y1
        asr     #$4,a,a
        move    a,x1                    ; tolerance = free/16
        move    x:(r6+$7),x0            ; ticks Q12.4 << 8 (0 = not published)
        clr     b                       ; candidate: 0 = nothing near
        move    n4,r5                   ; the P table (block preamble)
        move    #$28,n5                 ; + 40: the divisions
        move    (r5)+n5
        do      #10,>snapz
        move    p:(r5)+,y0              ; M << 11, smallest first
        mpy     y0,x0,a                 ; ticks*M
        sub     y1,a
        abs     a                       ; |d - free|
        cmp     x1,a
        tlt     y0,b                    ; within tolerance -> candidate
snapz:
; ---- knob moved? then held = candidate, else keep ---------------------------
        move    b,x1                    ; candidate (B2 clean: clr/Tcc only)
        move    x:(r6+$1),a             ; TIME (slot 1)
        and     #>$7f0000,a
        asr     #$10,a,a                ; knob, 0..127
        move    a,y0
        move    y:>$0908,x0             ; last knob
        move    y0,y:>$0908
        move    y:>$0909,b              ; held M<<11 (0 = free)
        cmp     x0,a                    ; knob - last
        tne     x1,b                    ; moved -> re-evaluated
        move    b,y:>$0909
; ---- TIME = held ? ticks*held : free ---------------------------------------
        move    b,y0
        move    x:(r6+$7),x0
        mpy     y0,x0,a                 ; 0 when free or unpublished
        move    #>16320,x1
        cmp     x1,a
        tgt     x1,a                    ; clamp to the line
        move    x:(r7+$2c),x1
        tst     a
        teq     x1,a                    ; free
        move    a,x:(r7+$2c)

        move    x:(r7+$2c),a            ; target, integer samples
        asl     #$8,a,a                 ; Q8
        move    a,x0
        move    y:>$0907,b              ; slewed TIME, Q8 (0 at boot)
        tst     b
        teq     x0,b                    ; boot: start AT the target
        move    b,y0
        sub     y0,a                    ; target - state
        asr     #$a,a,a                 ; /1024 per block
        add     y0,a                    ; state += step
        move    a,y:>$0907
        asr     #$8,a,a                 ; back to integer samples
        move    a,x:(r7+$2c)            ; TIME, as every consumer below sees it

        move    x:(r6+$2),x0            ; FDBK: slot 2 (one-aux re-slot)
        move    #$70,y1  
        mpy     x0,y1,a
        move    a,x:(r7+$2a)            ; FDBK, 0 .. ~0.87

        move    x:(r6+$3),x0            ; TONE: slot 3 (one-aux re-slot)
        move    #$70,y1  
        mpy     x0,y1,a
        add     #>$100000,a
        move    a,x:(r7+$29)            ; TONE, 0.125 (dark) .. 0.99 (bright)

        move    x:(r6+$4),x0            ; PING: slot 4 (one-aux re-slot)
        move    x0,a
        move    a,x:(r7+$2b)            ; PING, 0 .. ~0.99
        move    #>$7fffff,a
        sub     x0,a
        move    a,x:(r7+$37)            ; 1 - PING

        move    x:(r6+$5),x0            ; MIX, slot 5
        move    x0,x:(r7+$3c)           ; MIX
        move    #>$7fffff,a
        sub     x0,a
        move    a,x:(r7+$3e)            ; 1 - MIX

        move    x:(r6),a                ; AUX, slot 0 (one-aux rig, 7 Sep 2026:
                                        ; every track's one send, this host's
                                        ; included; was ->DEL on p10)
        and     #>$7f0000,a
        move    a,x:(r7+$2d)            ; AUX, this block

; ---- MODE: engine select, page-2 slot 7 ($c bits 8-15) -- v2 spine --------
; Same field, same extract, same MSB-aligned convention as BusVerb's MODE
; (modules/busverb/reverb_server.asm). STAGE 1: CLEAN is the only engine, so every value
; -- including whatever an undefined descriptor slot leaves in this word on
; hardware -- runs CLEAN. When PITCH lands, the dispatch compares MSB-aligned
; short immediates on $69, and unknown values must keep falling through to
; CLEAN: a wrong select degrades to the trad delay, never to silence. The
; descriptor's MODE select (RENAMES/DEFAULTS/PAGE2_COUNTS in build_bus.py)
; lands with the second mode. DMODE=n (build_bus.py) substitutes a literal
; at the marker below (dsp_host can also drive companions via -params 7/9/11;
; the override forces the decoded VALUE, so DFRZ=2 means frozen, not SYNC).
        move    x:(r6+$c),a
        and     #>$ff0000,a             ; slot 6's KNOB field (v6, 4 Sep 2026;
                                        ; slot 7's companion byte before --
                                        ; moved so the panel's page-2 knob
                                        ; editor can set MODE from a screen)
        move    a1,x0
        move    x0,a                    ; A2-clean (AND cleans A1 only); the
                                        ; knob field is already MSB-aligned
                                        ; ($010000 per step), so no shift
; DMODE_OVERRIDE
        move    a,x:(r7+$20)            ; MODE, this block (0 = CLEAN)

; ---- SHIFTED-OUTPUT flag: which modes replace the wet with $24/$25 --------
; GRAIN and REVERSE both leave their result in the shifted-output taps
; are substituted into the wet AFTER the lines are written (stage 2c, so
; nothing shifted can re-enter the feedback). Resolving "is this such a mode"
; ONCE PER BLOCK instead of at the substitution point makes that per-sample
; test a `tst`, the same shape as FREEZE's -- it costs two words fewer than
; the single compare it replaces and does not grow when a fourth mode wants
; the same treatment. Branchless: cmp sets Z, the intervening moves do not
; disturb it, and teq moves a CLEAN register in (never a hand-rolled mask).
        clr     a
        move    x:(r7+$20),b            ; MODE
        move    #$1,x0               ; 1 << 16 = GRAIN
        cmp     x0,b
        move    #>$1,x0
        teq     x0,a
        move    #$2,x0               ; 2 << 16 = REVERSE
        cmp     x0,b
        move    #>$1,x0
        teq     x0,a
        move    a,x:(r7-$16)            ; nonzero = the wet comes from $24/$25
        clr     a
        move    #$2,x0               ; 2 << 16 = REVERSE
        cmp     x0,b                    ; b = MODE, still
        move    #>$1,x0
        teq     x0,a
        move    a,x:(r7+$23)            ; skipR
        move    #>$3fff,a
        move    #>$7fff,x0
        teq     x0,a                    ; the flag survives the moves
        move    a,x:(r7+$22)            ; the L ring's mask
        move    x:(r7+$2b),a
        move    #$0,x0 
        teq     x0,a
        move    a,x:(r7+$2b)            ; PING 0 in REVERSE
        move    x:(r7+$37),a
        move    #>$7fffff,x0
        teq     x0,a
        move    a,x:(r7+$37)            ; 1 - PING = 1 in REVERSE

        move    x:(r6+$d),a
        and     #>$7f00,a               ; slot 9's companion field: BITS 8-15
        asr     #$8,a,a
; DINT_OVERRIDE
        move    a1,x0
        move    x0,a                    ; A2-clean
        move    a,x:(r7+$16)            ; the RAW index, 0..3

; ---- MIDI note -> latched note (branch midi, 24 Aug 2026; v5: GRAIN pitch) -
; The ColdFire cave (modules/tempo-sync/tempo_cave.s v2) re-stores the host
; track's held MIDI note into r6+$9 every frame (bits 8-15); 0 = released or
; no cave. HOLD semantics: the last note LATCHES in a core-private Y slot for
; as long as any note has ever arrived -- a track that never sees MIDI behaves
; exactly as before. Since v5 the latched note drives GRAIN's continuous
; pitch (2^((note-84)/12), the OT's 84 = unison) in place of the RATE knob;
; the interval ladder it used to select died with PITCH mode.
        move    x:(r6+$9),a
        and     #>$7f00,a               ; the note, bits 8-15
        asr     #$8,a,a
; DNOTE_OVERRIDE
        move    a1,x0
        move    x0,a                    ; A2-clean
        tst     a
        move    y:>$090a,b              ; latched note (0 = never)
        tne     x0,b                    ; a new note replaces it; a release
                                        ; (0) leaves it -- the moves between
                                        ; tst and tne do not touch the flags
        move    b,y:>$090a
        move    b,x:(r7+$21)            ; this block's note for GRAIN (0 = none)

        move    x:(r6+$c),a             ; $c: slot 7 is its COMPANION field
        and     #>$7f00,a               ; (bits 8-15); knob<<8, so <<5 more
        asl     #$5,a,a         ; = knob<<13, the x8 RELAW (18 Aug 2026): the old law's
        move    a1,x0
        move    x0,a                    ; A2-clean
        move    x:(r7+$20),b            ; MODE
        move    #$1,x0               ; 1 << 16 = GRAIN
        cmp     x0,b
        bne     wowlive
        move    #>$18000,a              ; 12 << 13
wowlive:
        move    a,x:(r7-$1c)            ; WOWD
        asr     #$3,a,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$1b)            ; FLTD = WOWD/8

; ---- RATE: modulation speed -- page-2 slot 8 KNOB (18 Aug 2026) -----------
; One factor, val/64 (64 = exactly 1x, 0 = frozen, 127 = ~2x), scaling BOTH
; LFO increments so the anti-lock wow:flutter ratio survives. The constants
; are PRE-DOUBLED ($130 = 2x$98, $ada = 2x$56d) so the mpy's val/128 becomes
; val/64 with NO post-shift -- an asl after truncation broke bit-identity at
; the default by one LSB of the odd flutter increment, which is exactly the
; kind of failure the DPTH=0 gate exists to catch.
; Results live in CORE-PRIVATE Y 0901h/0902h (see the warning below;
; XBUS): r7 is full, and the server-role lock guarantees ONE delay per bank,
; so the shared words have one writer.
        move    x:(r6+$d),a
        and     #>$7f0000,a             ; MRAT knob field
        move    a1,x0
        move    x:(r7+$20),b            ; v5.1: in GRAIN MRAT is density and the
        move    #$1,x0               ; mod rate is fixed at exactly 1x (64),
        cmp     x0,b                    ; the DPTH=0 bypass law's own value.
        move    #$40,x0              ; 64 << 16 -- a move between the cmp
        teq     x0,a                    ; and the Tcc is fine; Tcc's DESTINATION
        move    a1,x0                   ; is an accumulator, never a register
        move    #>$130,y1
        mpy     x0,y1,a                 ; wow inc = $98 * val/64
; ⚠️ 0901h-0904h: CORE-PRIVATE Y, and the ZERO-PADDED SPELLING IS LOAD-BEARING.
; (0904h is the v6 freeze-crossfade ramp r -- same family, same reasoning.)
; These three words (wow inc / flutter inc / drive d) lived at shared-window
; Y 0x360d3-5 for one image (R36) and were DEAD ON HARDWARE: -VRB and FRZE
; proved the decodes execute and the $e word publishes, yet DPTH/RATE/DRV all
; behaved as zero -- the per-block writes and in-loop reads do not meet on
; silicon there, mechanism unknown (they were the first in-loop absolute Y
; reads in the shared window; the emulator's flat memory passes either way,
; so no local test can see whatever silicon does). Moved to the OLD BUS
; RANGE, core-private low Y -- empty since XBUS relocated the bus out, and
; hardware-proven for exactly this write-per-block/read-per-sample pattern
; by stock and the v121 bus. The `$09xx` spelling dodges build_bus.py's
; blanket `$9xx` relocation regex ON PURPOSE: `0901h` would be rewritten to
; 0x36001, straight into the shared REVERB accumulator. build_bus
; census-guards the count (exactly 8 refs since v6: RATE's four plus the
; freeze ramp's four; the old "6" here predated d's move to r7+$83).
        move    a,y:>$0901
        move    #>$ada,y1
        mpy     x0,y1,a                 ; flutter inc = $56d * val/64
        move    a,y:>$0902

        move    x:(r6+$e),a
        and     #>$7f00,a               ; slot 11's companion field: BITS 8-15. No
                                        ; shift: $26 is only ever tested zero /
                                        ; nonzero, so the index's scale is moot.
                                        ; (24 Aug 2026: briefly a 4-way with a
                                        ; SYNC bit; on the unit position 2 froze
                                        ; too, and freeze is performative --
                                        ; Sam: SYNC does not live here.)
; DFRZ_OVERRIDE
; (24 Aug 2026: a crossfader -> FREEZE hard-lock lived here for an evening
; and was removed at Sam's request -- nothing is to be welded to the fader.
; Page 1 scene-locks morph like any stock effect; page 2 cannot be locked,
; and that is where it stays. The cave still publishes fader+1 at r6+$8,
; unread.)
        move    a1,x0
        move    x0,a                    ; A2-clean before the store
        move    a,x:(r7-$23)            ; 0 = running, nonzero = frozen
        tst     a
        move    y:>$0904,b              ; r (core-private, like RATE/DRV's
        move    #>$7fffff,x0
        teq     x0,b                    ; running -> re-arm
        move    b,y:>$0904

        move    x:(r6+$c),a             ; MDEP's companion field: SCATTER in
        and     #>$7f00,a               ; GRAIN (v5.1 -- the mod depth is fixed there)
        move    a1,x0
        move    x0,a                    ; A2-clean (AND cleans A1 only)
        asl     #$8,a,a                 ; -> knob<<16
        move    a,x:(r7+$13)            ; SPRAY, 0 .. ~0.992 as Q23

        move    x:(r7+$16),a            ; select index, 0..127
        move    #>$4,x0
        cmp     x0,a
        tgt     x0,a                    ; 4 and up: the garbage row
        asl     #$3,a,a                 ; row stride 8
        move    n4,x0                   ; the table base (see the block preamble)
        add     x0,a
        move    a,r5
        move    p:(r5)+,a               ; S
        move    a,x:(r7+$17)            ; REVERSE segment length
        move    p:(r5)+,a               ; 2^23 / S
        move    a,x:(r7+$18)            ; REVERSE phase step
        move    p:(r5)+,a               ; 32704 - 2S
        move    a,x:(r7+$d)             ; the cap for this size
        move    p:(r5)+,a               ; G - 1
        move    a,x:(r7-$11)            ; GRAIN mask
        move    p:(r5)+,a               ; G/4
; GRAINOFF
        move    a,x:(r7-$10)            ; G/4, the grain-to-grain offset
        move    p:(r5)+,a               ; 2^(23-k)
        move    a,x:(r7-$f)             ; GRAIN window multiplier
        move    p:(r5),a                ; 2^(32-k)
        move    a,x:(r7-$a)             ; GRAIN pitch-ceiling multiplier
        move    x:(r7+$2c),a            ; TIME
        move    x:(r7+$d),x0
        sub     x0,a                    ; sub/branch, not cmp (the
        tst     a                       ; cmp-encodes-as-max trap family)
        ble     rlagok
        clr     a                       ; over the cap: excess -> 0
rlagok:
        add     x0,a                    ; min(TIME, cap)
        move    a,x:(r7+$19)            ; RLAG0, the reversed chunk's lag floor

        move    x:(r7-$11),b            ; mask = G - 1
        move    #>12286,a               ; 16383 - 4096 - 1
        sub     b,a                     ; the lag cap for this G
        move    a,x:(r7-$e)            ; park the cap
        move    x:(r7+$2c),a            ; TIME
        move    x:(r7-$e),x0
        sub     x0,a
        tst     a
        ble     gvlag                   ; TIME <= cap: keep it
        clr     a                       ; over: excess -> 0, i.e. clamp
gvlag:
        add     x0,a                    ; min(TIME, cap) = lag
        move    a,x:(r7-$d)            ; park lag for the pitch ceiling
        move    x:(r7-$11),x0
        add     x0,a                    ; + G - 1
        add     #>$3,a                  ; + 3 = lag + G + 2
        move    a,x:(r7-$e)            ; the read distance base
; ---- GRAIN PITCH (v5): rstep, the grain's read advance per sample, Q9 ----
; 512 = unity. From the RATE knob, +-2 octaves: r = 2^((RATE-64)/32), 64 =
; unison, 96 = +12, 32 = -12. From a latched MIDI note when one has ever
; arrived ($6a, the tempo cave's r6+$9): r = 2^((note-84)/12), clamped to
; +-24 semitones -- the same law the retired PITCH mode drove from the note.
; 2^f for f in [0,1) is a cubic, 1 + f(0.6931 + f(0.2402 + 0.0558 f)), error
; < 0.2 cent; the octave part is a shift. Both paths meet at gvoct with
; oct in a (-2..2, sign-extended) and f in x:(r7+$3d) (Q23).
        move    x:(r7+$21),a
        tst     a
        beq     gvknob
; note path: st = note - 84 clamped to +-24; oct' = (st + 24) / 12 by ladder
        move    #>84,x0
        sub     x0,a                    ; st
        move    #>$ffffe8,x0            ; -24
        cmp     x0,a
        tlt     x0,a
        move    #>24,x0
        cmp     x0,a
        tgt     x0,a
        add     x0,a                    ; st + 24, 0..48
        move    a,x:(r7-$c)            ; park (integer)
        move    #$0,b                    ; oct'
        move    #>12,x0
        cmp     x0,a                    ; the ladder: subtract 12 while >= 12
        blt     gvn0
        sub     x0,a
        move    #>1,b
        cmp     x0,a
        blt     gvn0
        sub     x0,a
        move    #>2,b
        cmp     x0,a
        blt     gvn0
        sub     x0,a
        move    #>3,b
        cmp     x0,a
        blt     gvn0
        sub     x0,a
        move    #>4,b
gvn0:
        asl     #$13,a,a                ; rem << 19 = rem/16 in Q23 (<= 0.69)
        move    a1,x0
        move    #>$555555,y1            ; 2/3
        mpy     x0,y1,a                 ; rem/24
        asl     #$1,a,a                 ; rem/12 = f, Q23
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$c)            ; f, Q23
        move    b,a
        move    #>2,x0
        sub     x0,a                    ; oct = oct' - 2
        bra     gvoct
gvknob:
; knob path: e = RATE - 64 (-64..63); oct = e >> 5; f = (e & 31) << 18
        move    x:(r6+$e),a             ; PTCH: page-2 slot 10's KNOB field
        and     #>$7f0000,a             ; a plain knob, val << 16
        move    a1,x0
        move    x0,a
        asr     #$10,a,a                ; the integer knob 0..127
        move    #>64,x0
        sub     x0,a                    ; e
        move    a,x:(r7-$c)            ; park e
        and     #>$1f,a
        asl     #$12,a,a                ; (e & 31) << 18 = f in Q23
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$0)            ; f, Q23 (park)
        move    x:(r7-$c),a
        asr     #$5,a,a                 ; oct = e >> 5, -2..1 (arithmetic)
        move    a1,x0
        move    x0,a
        move    x:(r7+$0),x0
        move    x0,x:(r7-$c)           ; f into its slot
gvoct:
        move    a,x:(r7+$0)            ; park oct
; 2^f - 1 = f * (c1 + f * (c2 + c3 * f))
        move    x:(r7-$c),x0           ; f
        move    #>$072470,y1            ; c3 = 0.0558
        mpy     x0,y1,a
        add     #>$1ebfce,a             ; + c2 = 0.2402
        move    a,y1
        mpy     x0,y1,a                 ; f * (c2 + c3 f)
        add     #>$58b90c,a             ; + c1 = 0.6931
        move    a,y1
        mpy     x0,y1,a                 ; 2^f - 1, Q23, 0 .. 0.99
        asr     #$e,a,a                 ; * 512 -> Q9 integer 0..511
        move    a1,x0
        move    x0,a
        add     #>512,a                 ; rstep at oct 0: 512 .. 1023
; the octave: shift by oct
        move    a,x:(r7-$b)
        move    x:(r7+$0),a
        tst     a
        beq     gvrdone
        move    #>1,x0
        cmp     x0,a
        beq     gvr1
        move    #>2,x0
        cmp     x0,a
        beq     gvr2
        move    #>$ffffff,x0            ; -1
        cmp     x0,a
        beq     gvrm1
        move    x:(r7-$b),a            ; -2
        asr     #$2,a,a
        bra     gvrst
gvrm1:
        move    x:(r7-$b),a
        asr     #$1,a,a
        bra     gvrst
gvr1:
        move    x:(r7-$b),a
        asl     #$1,a,a
        bra     gvrst
gvr2:
        move    x:(r7-$b),a
        asl     #$2,a,a
gvrst:
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$b)
gvrdone:
; ---- the pitch CEILING: a grain running faster than the write head needs
; room in front of it. Its read starts lag + s + G + 2 behind the head and
; closes on it by G*(r-1) over its life, so r - 1 <= 1 + lag/G keeps it
; behind. rmax = 1024 + lag * 2^(9-k) via the per-size 2^(32-k) constant,
; one mpy; rstep is clamped to it, so a short TIME on a long grain quietly
; limits how far UP the pitch reaches (+12 always fits). The per-sample
; distance clamps in the reader are the belt to this brace.
        move    x:(r7-$d),x0           ; lag (integer, 0..12285)
        move    x:(r7-$a),y1           ; 2^(32-k)
        mpy     x0,y1,a                 ; a1 = lag * 2^(9-k)
        move    a1,x0
        move    x0,a
        add     #>1024,a                ; rmax
        move    a,x0
        move    x:(r7-$b),a
        cmp     x0,a
        tgt     x0,a                    ; rstep = min(rstep, rmax)
        move    a,x:(r7-$b)
        move    x:(r6+$d),a             ; MRAT's knob field: DENSITY in GRAIN
        and     #>$7f0000,a             ; (v5.1 -- the mod rate is fixed there)
        asr     #$14,a,a                ; knob >> 4 = dens3, 0..7
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$d)            ; dens3 (lag's park is consumed)
        move    #>7,b
        sub     a,b                     ; 7 - dens3
        move    b1,x0
        move    x0,b
        asl     #$14,b,b                ; (7-dens3) << 20 = n/8 in Q23
        move    b1,x0
        move    #>$492492,y1            ; 8/14 in Q23
        mpy     x0,y1,b                 ; n/14 (x0,y1 -- a SIGNED encode)
        move    #$40,x0  
        add     x0,b                    ; + 1/2
        move    b1,x0
        move    x0,b
        move    b,x:(r7-$c)            ; GRAIN makeup coeff, this block

        move    x:(r7+$27),a            ; LineL phase
        move    x:(r7+$22),x0           ; the L ring's mask ($7fff in REVERSE)
        and     x0,a
        move    x:(r7-$18),x0           ; LineL base
        move    x0,n1                   ; ... for the block
        move    a1,r1
        move    (r1)+n1                 ; LineL write pointer = base + phase

        move    x:(r7-$18),a            ; LineR base = LineL base + 0x4000
        move    #>$4000,x0
        add     x0,a
        move    a,n2                    ; ... for the block

        move    x:(r7+$28),a            ; LineR phase
        move    #>$3fff,x0
        and     x0,a
        move    a1,r2
        move    (r2)+n2                 ; LineR write pointer

; v2 SPINE: NO AGU MODULO. m1/m2 stay at the linear invariant ($ffffff);
; the TIME-behind read address is computed per sample and the write
; pointers are wrapped by hand below. n1/n2 are unused.

        move    #$1,n0                  ; the frame stride (a byte lands
        do      n7,>dlyend              ; LOW in an address register)

; ---- input: own dry mono sum + shared DELAY bus accumulator --------------
        move    x:(r0),a
        move    x:(r0+n0),x0
        add     x0,a
        asr     #$1,a,a
        move    a,x0                    ; own dry mono
        move    x:(r7+$2d),y1           ; IN, this track's send level
        mpy     x0,y1,a                 ; our contribution to the bus
        asr     #$3,a,a                 ; the 3 bits of headroom EVERY writer
                                        ; applies, so N of them cannot rail
                                        ; the sum before it is divided
        move    a,x:(r7+$34)            ; park our share
        move    x:(r7+$1a),a            ; this sample's ACC read address
        move    a,r5
        move    y:(r5),x0               ; last block's fully-summed sends
        move    x:(r7+$34),a
        add     x0,a                    ; the full sum, our own share included
        move    a,x0
        move    x:(r7+$36),y1           ; this block's bus gain 1/sqrt(N); N
                                        ; COUNTS US (see the resolve block)
        mpy     x0,y1,a                 ; hold total drive constant vs N --
                                        ; signed (2000c0): x0 is a bus sample
                                        ; and can be negative, y1 (the gain) never
        asl     #$3,a,a                 ; undo the writers' 3-bit headroom
        move    a,x:(r7+$34)            ; x_in = the averaged bus, us included
        move    x:(r7+$1a),a
        add     #>$1,a
        move    a,x:(r7+$1a)            ; advance ACC read pointer

; ---- the FEEDBACK LOOP's taps: ALWAYS the unshifted read (v2 stage 2c) ----
; NON-CASCADING PITCH. Until stage 2c the shifted taps WERE the loop's taps,
; so every repeat was shifted again: repeat n had been through the shifter n
; times and carried n generations of splice artifact. That compounding, not
; the splice itself, is most of what an ear calls "machine" -- and BusVerb
; hit exactly this and fixed it the same way (its shimmer deliberately cut
; its own cascade; see modules/busverb/reverb_server.asm's SHIMMER block).
;
; Now the loop recirculates the CLEAN tap and the shifter sits on the OUTPUT
; only, so every repeat is shifted exactly ONCE: a fixed-interval harmoniser
; on the delay's output rather than a climbing ladder. TONE, PING, FDBK and
; the write-back are all mode-blind and bit-identical to CLEAN's; the
; substitution happens after the lines are written (below), so nothing
; shifted ever re-enters the loop.
;
; ⚠️ The climb is GONE by construction -- +12 no longer walks up in octaves.
; That was the Crystal behaviour stage 2 chose on purpose; it is exactly
; what compounds the artifact, and the ear rejected it (12 Aug). If a climb
; is ever wanted back it belongs on a select, not as the only topology.
;
; ---- LOOP taps: lerped read at lag TIME + wow/flutter, EVERY mode ---------
; (18 Aug 2026.) This is TAPE's machinery promoted to the common path -- the
; loop's recirculating tap is the same in every mode since stage 2c, so the
; drift belongs to the INSTRUMENT, not to a mode. DPTH (p6, was WOW) sets the
; summed depth; RATE (p8) scales BOTH LFO increments by one factor, val/64
; with 64 = exactly 1x -- preserving the deliberate non-integer wow:flutter
; ratio that keeps the pair from ever locking. DPTH=0 reads lag TIME with
; fraction 0, which the lerp passes through exactly -- bit-identical to the
; old CLEAN taps, and that is the gate this refactor shipped under.
; The load-bearing depth bound is unchanged and rate-independent: wow+flutter
; sum <= 35.7 samples against TIME's floor of 64.
        move    x:(r7-$22),a           ; wow phase
        move    y:>$0901,x0           ; wow increment (core-private -- see RATE decode)
                                        ; (p8), computed per block. Y bus
                                        ; scratch, because r7 is full and the
                                        ; role lock means ONE delay per bank
        add     x0,a
        and     #>$7fffff,a
        move    a1,x0
        move    x0,a                    ; A2-clean; boot garbage dies here
        move    a,x:(r7-$22)
        bsr     smoothw                 ; s = g^2*(3-2g), 0..1 (v6 roll --
                                        ; the inline copy parked g^2 in $2a;
                                        ; smoothw parks in $5a, equally dead
                                        ; here)
        move    a1,x0
        move    x:(r7-$1c),y1         ; WOWD
        mpy     x0,y1,a                 ; s*depth
        asl     #$1,a,a
        move    x:(r7-$1c),x0
        sub     x0,a                    ; depth*(2s-1): centred, +-depth
        move    a,x:(r7-$20)            ; running mod total

        move    x:(r7-$21),a           ; flutter phase
        move    y:>$0902,x0           ; flutter increment (core-private,
                                        ; NOT a multiple of the wow: the
                                        ; anti-lock ratio survives RATE because
                                        ; ONE factor scales both) x RATE
        add     x0,a
        and     #>$7fffff,a
        move    a1,x0
        move    x0,a                    ; A2-clean; boot garbage dies here
        move    a,x:(r7-$21)
        bsr     smoothw                 ; s = g^2*(3-2g), 0..1 (v6 roll)
        move    a1,x0
        move    x:(r7-$1b),y1         ; FLTD
        mpy     x0,y1,a                 ; s*depth
        asl     #$1,a,a
        move    x:(r7-$1b),x0
        sub     x0,a                    ; depth*(2s-1): centred, +-depth
        move    x:(r7-$20),x0
        add     x0,a                    ; mod = wow + flutter, Q11.12 signed

; ---- split the offset: integer samples + Q23 fraction ---------------------
; asr floors (arithmetic, so negative offsets too) and the masked low 12
; bits are the POSITIVE remainder -- the pairing the lerp below assumes.
        move    a,x:(r7-$1f)            ; park mod
        asr     #$c,a,a                 ; integer samples, signed
        move    a1,x0
        move    x0,a                    ; move-to-accumulator sign-extends
        move    a,x:(r7-$20)            ; mod_int
        move    #>8,a
        move    x:(r7+$2c),x0           ; TIME
        sub     x0,a                    ; 8 - TIME = lowest legal mod
        move    a,x1
        move    x:(r7-$20),a
        cmp     x1,a
        tlt     x1,a                    ; below -> pin at low limit
        move    a,x:(r7-$20)
        move    #>16376,b
        move    x:(r7+$2c),x0
        sub     x0,b                    ; highest legal mod
        move    b,x1
        cmp     x1,a
        tgt     x1,a                    ; above -> pin at high limit
        move    a,x:(r7-$20)
        move    x:(r7-$1f),a
        and     #>$fff,a                ; fraction (A2 stale until cleaned)
        asl     #$b,a,a                 ; -> Q23
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$1d)            ; frac

; ---- TAPE Line L: lerped read at lag TIME + mod ---------------------------
        move    r1,a
        move    n1,n5
        bsr     modtap
        move    a,x:(r7+$30)          ; dL, wobbled -- the LOOP's own tap

; ---- TAPE Line R: lerped read at lag TIME + mod ---------------------------
        move    x:(r7+$23),a            ; skipR (REVERSE-32K): R's read would
        tst     a                       ; land in the mono ring's upper half
        bne     rskipr
        move    r2,a
        move    n2,n5
        bsr     modtap
        move    a,x:(r7+$31)          ; dR, wobbled
rskipr:
; ---- MODE dispatch: PITCH additionally computes the SHIFTED OUTPUT taps ---
; 0 and every unknown value run the loop's clean taps alone -- a wrong select
; degrades to the trad delay, never to silence (the stage-1 rule). The
; compare is the safe `cmp x0,a` form.
; MODEFORK_BEGIN -- cycle_count.py: BEGIN..first MID is the dispatch and
; always runs; each MID..next is one mutually exclusive alternative, and the
; tool charges dispatch + the WORST alternative, never every engine summed.
        move    x:(r7+$20),a
        move    #$1,x0               ; 1 << 16 = GRAIN (v5 numbering)
        cmp     x0,a
        beq     gmode
        move    #$2,x0               ; 2 << 16 = REVERSE
        cmp     x0,a
        beq     rmode
        bra     pdone                   ; CLEAN, and every unknown value
; MODEFORK_MID -- alternative 1: GRAIN

gmode:
; ---- PRNG advance: BusDelay's 23-bit xorshift 15/15/8 -------------------
        move    x:(r7-$31),a            ; state
        move    a1,x0
        asl     #$f,a,a
        and     #>$7fffff,a
        eor     x0,a                    ; x ^= (x << 15)
        move    a1,x0
        move    x0,a
        asr     #$f,a,a                 ; state is always positive, so the
        eor     x0,a                    ; arithmetic shift IS a logical one
        move    a1,x0
        move    x0,a
        asl     #$8,a,a
        and     #>$7fffff,a
        eor     x0,a                    ; x ^= (x << 8)
        move    a1,x0
        move    x0,a                    ; A2 clean before the store
        move    a,x:(r7-$31)
; ---- this sample's scatter candidate: prng * SPRAY -> 0..4095 samples ----
        move    a,x0                    ; state, 0 .. ~1.0 (always positive)
        move    x:(r7+$13),y1           ; SPRAY, Q23
        mpy     x0,y1,a                 ; both operands non-negative
        asr     #$b,a,a                 ; fraction -> integer samples
        and     #>$fff,a                ; belt and braces: it IS 0..4095
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$f)
        move    x:(r7-$31),b
        asr     #$5,b,b
        and     #>$7,b
        move    b1,x1                   ; bits, 0..7 (x1 is free in this mode)
        clr     b                       ; the muted form, BEFORE the compare
        move    x:(r7-$d),a            ; dens3
        sub     x1,a                    ; N SET == muted
        move    x:(r7-$f),x0           ; the live multiplier
        tpl     x0,b                    ; not muted -> take it
        move    b,x:(r7+$10)
; ---- age advance, masked by G-1 (also swallows size changes) -------------
        move    x:(r7-$17),a
        add     #>$1,a
        move    x:(r7-$11),x0
        and     x0,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$17)
        clr     b                       ; wet L accumulates in b
; ---- READER, line L: four grains, ROLLED (v5) ----------------------------
; Records of THREE words at r7+$40: s (latched scatter), w (window
; multiplier, 0 = muted), acc (read advance, Q14.9). Every latch is a Tcc
; reading the ONE `tst` of this grain's phase, with nothing but moves between
; them (the GRAIN 5d trap); the `add` that advances acc comes AFTER the last
; of them. Phase walks $5d by G/4 per trip; the wet sum lives in x:(r7+$1e)
; because b is the latch register inside the body.
        move    r7,a                    ; records at raw $40 = r7 - 9
        sub     #>$9,a                  ; (r7 is rebased by $49 here)
        move    a,r4                    ; (m4 is linear from the block preamble)
        move    x:(r7-$17),x0
        move    x0,x:(r7+$14)           ; cursor = age (grain 0's phase)
        move    n1,n5                   ; this line's base for the reads
        clr     a
        move    a,x:(r7-$2b)
; GRAINCNT
        do      #4,>gvlz
        move    x:(r7+$14),a            ; this grain's phase
        tst     a                       ; Z SET == its wrap
        move    a,x1                    ; phase, kept for the distance
        move    x:(r7+$f),x0           ; candidate scatter
        move    x:(r4),b
        teq     x0,b
        move    b,x:(r4)+               ; s
        move    b,x:(r7-$2c)            ; park s
        move    x:(r7+$10),x0           ; candidate multiplier (0 = muted)
        move    x:(r4),b
        teq     x0,b
        move    b,x:(r4)+               ; w
        move    b,y1                    ; w, the window multiplier
        move    #$0,x0 
        move    x:(r4),b
        teq     x0,b                    ; acc restarts at the wrap
        move    x:(r7-$b),x0           ; rstep
        add     x0,b                    ; acc += rstep
        move    b,x:(r4)+               ; -> the next record
        move    a,x0                    ; phase
        mpy     x0,y1,a                 ; a0 = wrap(2*phase/G), signed Q23
        move    a0,x0
        move    x0,a                    ; reloaded clean: A2 consistent
        abs     a
        move    a,x:(r7-$30)            ; park the window gain
        move    b,a                     ; acc
        and     #>$1ff,a                ; the fraction
        asl     #$e,a,a                 ; -> Q23
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$2f)            ; park frac
        move    b,a
        asr     #$9,a,a                 ; integer samples advanced
        move    a1,x0
        move    x:(r7-$e),a            ; lag + G + 2
        sub     x0,a                    ; - advance
        move    x:(r7-$2c),x0
        add     x0,a                    ; + s
        add     x1,a                    ; + phase = dist. ⚠️ THE PHASE TERM IS
        move    #>$2,x0
        cmp     x0,a                    ; never the head's own slot ...
        tlt     x0,a
        move    #>$3fff,x0
        cmp     x0,a                    ; ... and never past the line's end
        tgt     x0,a                    ; (a low pitch on a long grain pins
                                        ; at the oldest sample: a flat spot,
                                        ; not a wrap)
        move    a,x0
        move    r1,a                ; line L write pointer
        sub     x0,a                    ; W - dist
        and     #>$3fff,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$2d)            ; park the read phase
        move    a,r5
        move    y:(r5+n5),a             ; t0 (line L base in n5)
        move    a,x:(r7-$2e)
        move    x:(r7-$2d),a
        add     #>$1,a                  ; one sample NEWER
        and     #>$3fff,a
        move    a1,r5
        move    y:(r5+n5),a             ; t1
        move    x:(r7-$2e),x0
        sub     x0,a                    ; t1 - t0, signed
        move    a1,x0                   ; -> FIRST mpy operand
        move    x:(r7-$2f),y1           ; frac
        mpy     x0,y1,a
        move    x:(r7-$2e),x0
        add     x0,a                    ; tap = t0 + frac*(t1-t0)
        move    a,x0                    ; LIMITING move
        move    x:(r7-$30),y1           ; window gain
        mpy     x0,y1,a
        move    x:(r7-$2b),b
        add     b,a
        move    a,x:(r7-$2b)       ; wet L +=
        move    x:(r7+$14),a            ; next grain: a quarter further round
        move    x:(r7-$10),x0
        add     x0,a
        move    x:(r7-$11),x0
        and     x0,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$14)
gvlz:
; ---- wet L = sum of four * makeup --------------------------------------
; four windows at quarter offsets sum to exactly 2, so the makeup coeff's
; 1/2 at full density is unity and its 1.0 top is +6 dB for the sparsest
; gate -- the v2 arithmetic, kept.
        move    x:(r7-$2b),x0
        move    x:(r7-$c),y1           ; makeup coeff
        mpy     x0,y1,b                 ; (a +6 dB asl sat here for a day, 12 Sep
                                        ; 2026, sized on the clobbered reader:
                                        ; whole, GRAIN is +2.1 dB RMS / +6.6 dB
                                        ; peak over CLEAN with it, peaks level
                                        ; without -- the level a return wants)
; GRAINMK
        move    b,x:(r7-$25)            ; shifted OUTPUT tap L
; ---- READER, line R: four grains, ROLLED (v5) ----------------------------
; Records of THREE words at r7+$4c: s (latched scatter), w (window
; multiplier, 0 = muted), acc (read advance, Q14.9). Every latch is a Tcc
; reading the ONE `tst` of this grain's phase, with nothing but moves between
; them (the GRAIN 5d trap); the `add` that advances acc comes AFTER the last
; of them. Phase walks $5d by G/4 per trip; the wet sum lives in x:(r7+$1f)
; because b is the latch register inside the body.
        move    r7,a                    ; records at raw $4c = r7 + 3
        add     #>$3,a                  ; (r7 is rebased by $49 here)
        move    a,r4
        move    x:(r7-$17),x0
        move    x0,x:(r7+$14)           ; cursor = age (grain 0's phase)
        move    n2,n5                   ; this line's base for the reads
        clr     a
        move    a,x:(r7-$2a)
; GRAINCNT
        do      #4,>gvrz
        move    x:(r7+$14),a            ; this grain's phase
        tst     a                       ; Z SET == its wrap
        move    a,x1                    ; phase, kept for the distance
        move    x:(r7+$f),x0           ; candidate scatter
        move    x:(r4),b
        teq     x0,b
        move    b,x:(r4)+               ; s
        move    b,x:(r7-$2c)            ; park s
        move    x:(r7+$10),x0           ; candidate multiplier (0 = muted)
        move    x:(r4),b
        teq     x0,b
        move    b,x:(r4)+               ; w
        move    b,y1                    ; w, the window multiplier
        move    #$0,x0 
        move    x:(r4),b
        teq     x0,b                    ; acc restarts at the wrap
        move    x:(r7-$b),x0           ; rstep
        add     x0,b                    ; acc += rstep
        move    b,x:(r4)+               ; -> the next record
        move    a,x0                    ; phase
        mpy     x0,y1,a                 ; a0 = wrap(2*phase/G), signed Q23
        move    a0,x0
        move    x0,a                    ; reloaded clean: A2 consistent
        abs     a
        move    a,x:(r7-$30)            ; park the window gain
        move    b,a                     ; acc
        and     #>$1ff,a                ; the fraction
        asl     #$e,a,a                 ; -> Q23
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$2f)            ; park frac
        move    b,a
        asr     #$9,a,a                 ; integer samples advanced
        move    a1,x0
        move    x:(r7-$e),a            ; lag + G + 2
        sub     x0,a                    ; - advance
        move    x:(r7-$2c),x0
        add     x0,a                    ; + s
        add     x1,a                    ; + phase = dist. ⚠️ THE PHASE TERM IS
        move    #>$2,x0
        cmp     x0,a                    ; never the head's own slot ...
        tlt     x0,a
        move    #>$3fff,x0
        cmp     x0,a                    ; ... and never past the line's end
        tgt     x0,a                    ; (a low pitch on a long grain pins
                                        ; at the oldest sample: a flat spot,
                                        ; not a wrap)
        move    a,x0
        move    r2,a                ; line R write pointer
        sub     x0,a                    ; W - dist
        and     #>$3fff,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7-$2d)            ; park the read phase
        move    a,r5
        move    y:(r5+n5),a             ; t0 (line R base in n5)
        move    a,x:(r7-$2e)
        move    x:(r7-$2d),a
        add     #>$1,a                  ; one sample NEWER
        and     #>$3fff,a
        move    a1,r5
        move    y:(r5+n5),a             ; t1
        move    x:(r7-$2e),x0
        sub     x0,a                    ; t1 - t0, signed
        move    a1,x0                   ; -> FIRST mpy operand
        move    x:(r7-$2f),y1           ; frac
        mpy     x0,y1,a
        move    x:(r7-$2e),x0
        add     x0,a                    ; tap = t0 + frac*(t1-t0)
        move    a,x0                    ; LIMITING move
        move    x:(r7-$30),y1           ; window gain
        mpy     x0,y1,a
        move    x:(r7-$2a),b
        add     b,a
        move    a,x:(r7-$2a)       ; wet R +=
        move    x:(r7+$14),a            ; next grain: a quarter further round
        move    x:(r7-$10),x0
        add     x0,a
        move    x:(r7-$11),x0
        and     x0,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$14)
gvrz:
; ---- wet R -------------------------------------------------------------
        move    x:(r7-$2a),x0
        move    x:(r7-$c),y1
        mpy     x0,y1,b                 ; (a +6 dB asl sat here for a day, 12 Sep
                                        ; 2026, sized on the clobbered reader:
                                        ; whole, GRAIN is +2.1 dB RMS / +6.6 dB
                                        ; peak over CLEAN with it, peaks level
                                        ; without -- the level a return wants)
; GRAINMK
        move    b,x:(r7-$24)            ; shifted OUTPUT tap R
        bra     pdone
; MODEFORK_MID -- alternative 2: REVERSE

rmode:
        move    x:(r7+$15),a            ; segment phase
        move    x:(r7+$18),x0           ; step = 2^23 / S
        add     x0,a
        and     #>$7fffff,a             ; wrap: one segment
        move    a1,x0
        move    x0,a                    ; A2-clean; boot garbage dies here
        move    a,x:(r7+$15)
; ---- head 0: lag and window from the phase -------------------------------
        move    a1,x0                   ; phase
        move    x:(r7+$17),y1           ; S, non-negative
        mpy     x0,y1,a                 ; p = phase*S/2^23, EXACT (the
                                        ; product is a whole multiple of
                                        ; 2^23, so nothing is rounded)
        asl     #$1,a,a                 ; 2p -- the write pointer's run-away
        move    a1,x0
        move    x:(r7+$19),a            ; RLAG0
        add     x0,a
        move    a,x:(r7+$d)            ; lag0, shared by both lines
        move    x:(r7+$15),a            ; phase again
        bsr     smoothw                 ; s = g^2*(3-2g) (v6 roll)
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$e)            ; g0
; ---- head 1: half a segment further on, same machinery -------------------
        move    x:(r7+$15),a
        move    #$40,x0  
        add     x0,a
        and     #>$7fffff,a
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$12)            ; park phase1
        move    a1,x0
        move    x:(r7+$17),y1
        mpy     x0,y1,a
        asl     #$1,a,a
        move    a1,x0
        move    x:(r7+$19),a
        add     x0,a
        move    a,x:(r7+$f)            ; lag1
        move    x:(r7+$12),a
        bsr     smoothw                 ; (v6 roll)
        move    a1,x0
        move    x0,a
        move    a,x:(r7+$10)            ; g1, and g0+g1 == 1 exactly
; ---- Line L: both heads, windowed and summed -----------------------------
        move    n1,n5                   ; the L base (the ring's, in REVERSE)
        move    r1,a                    ; LineL write pointer
        move    x:(r7+$d),x0           ; lag0
        sub     x0,a
        and     #>$7fff,a               ; read phase in the 32K MONO ring
        move    a1,r5                   ; (REVERSE-32K, 13 Sep 2026; the base
        move    y:(r5+n5),a             ; is 0x8000-aligned too) tap, head 0
        move    a,x0                    ; possibly negative -> FIRST operand
        move    x:(r7+$e),y1           ; g0
        mpy     x0,y1,a
        move    a,b
        move    r1,a
        move    x:(r7+$f),x0           ; lag1
        sub     x0,a
        and     #>$7fff,a
        move    a1,r5
        move    y:(r5+n5),a             ; tap, head 1
        move    a,x0
        move    x:(r7+$10),y1           ; g1
        mpy     x0,y1,a
        add     b,a
        move    a,x:(r7-$25)            ; shifted OUTPUT tap L -- NOT $79
        move    a,x:(r7-$24)            ; ... and R: the reverse is MONO
                                        ; (REVERSE-32K; the R line is not
                                        ; written in this mode)
; MODEFORK_END
pdone:

; ---- one-pole damping in the feedback path: s += c*(d-s) ------------------
        move    x:(r7+$2e),b            ; state L
        move    x:(r7+$30),a            ; dL
        sub     b,a
        move    a,x0
        move    x:(r7+$29),y1           ; TONE coefficient
        mpy     x0,y1,a
        add     b,a
        move    a,x:(r7+$2e)            ; new state L
        move    a,x:(r7+$32)            ; fL == this sample's wet L

        move    x:(r7+$2f),b            ; state R
        move    x:(r7+$31),a            ; dR
        sub     b,a
        move    a,x0
        move    x:(r7+$29),y1
        mpy     x0,y1,a
        add     b,a
        move    a,x:(r7+$2f)            ; new state R
        move    a,x:(r7+$33)            ; fR == this sample's wet R

; ---- ping-pong crossfeed matrix, feedback path only -----------------------
        move    x:(r7+$32),x0           ; fL
        move    x:(r7+$37),y1           ; 1-PING
        mpy     x0,y1,a
        move    x:(r7+$33),x0           ; fR
        move    x:(r7+$2b),y1           ; PING
        mpy     x0,y1,b
        add     b,a                     ; fbIntoL
        move    a,x:(r7+$35)

        move    x:(r7+$33),x0           ; fR
        move    x:(r7+$37),y1
        mpy     x0,y1,a
        move    x:(r7+$32),x0           ; fL
        move    x:(r7+$2b),y1
        mpy     x0,y1,b
        add     b,a                     ; fbIntoR
        move    a,x:(r7+$38)

        move    x:(r7+$35),x0           ; fbIntoL
        move    x:(r7+$2a),y1           ; FDBK
        mpy     x0,y1,a
        move    x:(r7+$34),x0           ; x_in
        add     x0,a
        move    x:(r7+$30),x1           ; the unshifted tap, this sample
        bsr     satdrv
        move    a,y:(r1)+                ; LineL write, advance

        move    x:(r7+$23),a            ; skipR (REVERSE-32K): no R write, it
        tst     a                       ; would land in the mono ring's upper half
        bne     rskipw
        move    x:(r7+$38),x0           ; fbIntoR
        move    x:(r7+$2a),y1
        mpy     x0,y1,a
        move    x:(r7+$34),x0           ; x_in
        move    x:(r7+$37),y1           ; 1 - PING
        mac     x0,y1,a                 ; + the direct input's share
; sat + drive, SHARED: the transform is identical for both lines, so it is a
; bsr subroutine (satdrv, end of file) -- the roll that paid for DRIVE's
; words. In: a = the value about to be written. Out: a. Clobbers b/x0/y0/y1
; and $2f/$30, none live across this point in either channel.
        move    x:(r7+$31),x1           ; LineR's raw tap (see the L note)
        bsr     satdrv
        move    a,y:(r2)+                ; LineR write, advance -- no x_in term
rskipw:

        move    r1,a
        move    x:(r7+$22),x0
        and     x0,a
        move    a1,r1                   ; the masked phase (a1 needs no A2-clean)
        move    (r1)+n1                 ; + LineL base
        move    r2,a
        and     #>$3fff,a
        move    a1,r2
        move    (r2)+n2                 ; + LineR base

        move    x:(r7-$16),a            ; SHIFTED flag: PITCH or GRAIN
        tst     a
        move    x:(r7-$25),x0           ; shifted L
        move    x:(r7+$32),b            ; loop's wet L
        tne     x0,b
        move    b,x:(r7+$32)
        move    x:(r7-$24),x0           ; shifted R
        move    x:(r7+$33),b
        tne     x0,b
        move    b,x:(r7+$33)

; ---- own track: DRY AT UNITY + WET (v5, 23 Aug 2026) ----------------------
; The host track is still a RETURN in every bus-arithmetic sense -- its audio
; reaches the ENGINE only through IN, it is counted as a client only while
; IN>0, and its OT track fader scales the whole output -- but its own dry now
; passes through at unity underneath the wet. v3 stage 1's wet-alone output
; meant a sample on the delay's track with IN=0 was SILENT ("the effect
; deleted my audio"); Sam hit exactly that in the field, 23 Aug 2026, and
; called it: a return should not mute its host.
;
; Why unity and not a knob: the control story is already complete. Dry level
; is the track fader; the host's own wet amount is IN; everyone else's wet
; amount is their ->DELAY send. A DRY knob would duplicate the fader and cost
; a cloned descriptor (the formatter-inheritance trap family) for nothing.
;
; What v3 stage 1 fixed STAYS FIXED: the MIX image-walk cannot recur (the dry
; is added at unity, never crossfaded against the wet's different stereo
; geometry), and the host still gets no privileged engine drive -- IN puts it
; through the same 3-bit headroom and 1/N auto-gain as every sender. With
; a silent host track the added dry is zero and the output is bit-identical
; to v3's wet-alone, so pure-return usage is unchanged. The sum saturates on
; store like any dry+wet mixer; that is accepted, not guarded.
;
; (v3's history, kept short: v1 was `dry + wet*MIX`, v2 stage 5c a crossfade,
; both retired 17 Aug 2026 because they privileged the host's dry as the
; crossfade reference and its engine drive was immune to the 1/N -- measured
; as a 0.00 -> 7.82 dB image walk across MIX's travel. IN defaults to 0 --
; load-bearing, see build_bus.py's DEFAULTS: a nonzero default registers an
; audio-less client and dilutes every real sender.)
; ---- DRIVE MAKEUP (18 Aug 2026): out = wet * (1 + d/2), OUTPUT STAGE ONLY --
; (gone 14 Sep 2026 with d pinned to 0 since 5 Sep -- the wet is taken as is;
; the note stays for the day a drive comes back)
; The V0b/V127b captures proved the drive WORKS (peak -4.2 dB, crest -2.5,
; harmonics +5.3) and also why it reads as "not much": flat-top without
; makeup is quieter-and-harsher, not driven. +3.5 dB at full d matches the
; measured loss. ⚠️ OUTPUT STAGE ONLY, never inside satdrv: makeup on the
; recirculating write is loop gain, and the drive curve's whole safety
; argument is that it adds none.
;
; The dry is read STRAIGHT FROM THE BUFFER at the store site -- x:(r0) still
; holds this frame's input because nothing between the input read and here
; writes the audio buffer (n0 stays 1 throughout the loop). No stash slot,
; no r7 pressure. The old `move a,b / move x0,a / add b,a` dance collapsed
; to `add x0,a` (same a1 result: the dance truncated d*wet/2's low word via
; the limiting a->b move, but those bits sit below the stored a1 either way
; and the unity add cannot carry up from a0) -- the two words that freed per
; channel are exactly what the dry add costs, so v5 is net ZERO program
; words on payload B, which had 1 free.
; IN-KEYED WET MAKEUP (v8, 23 Aug 2026 -- the reverb's law, ported on Sam's
; "delay wet is quiet"): out gains + 2*IN*wet, so full IN lifts the wet
; +9.5 dB while IN=0 adds EXACTLY zero -- every send-fed return level stays
; bit-identical, drive included (additive term from the PRE-drive wet, so
; the drive path's store-clamp behaviour is untouched). y0 is free across
; this whole block; the mpy is the audited-signed y0,x0 form.
; ---- OUTPUT STAGE (one-aux rig, 7 Sep 2026) --------------------------------
; The stage output is out = in*(1-MIX) + wet*MIX per channel, where `in` is
; this sample's chain input x_in ($7d: the auto-gained aux, this host's AUX
; included) and wet is the final (drive, x1.5, ping-shelved) tap. It is
; PUBLISHED stereo to the shared DELAY OUTPUT buffer (the return station
; reads it two buffers back) and its MONO average goes to the CHAIN buffer at
; $901 at unity -- the reverb's input while this stage is live. The host
; prints wet*MIX under its dry, or nothing while a return is live (RETD).
; (The IN-keyed wet makeup and the -VRB send went with their knobs.) Every
; mpy is an audited-signed order: y0,x0 or x0,y1.
        move    x:(r7+$34),y0           ; x_in, this sample's chain input
        move    x:(r7+$3e),x0           ; 1 - MIX
        mpy     y0,x0,b                 ; in * (1 - MIX)
        move    b,x:(r7+$25)            ; the passthrough term, both channels
        move    x:(r7+$32),x0           ; wet L = fL
        move    x0,a                    ; (was wet * (1 + d/2) with d = 0)
        move    x0,b
        asr     #$1,b,b                 ; wet/2 -> x1.5 both channels (R58)
        add     b,a
        move    a,x0                    ; wet L, final
        move    x:(r7+$3c),y1           ; MIX
        mpy     x0,y1,a                 ; wet * MIX
        move    a,x0                    ; x0 = wet*MIX: what the host prints
        move    x:(r7+$25),b
        add     x0,b                    ; b = stage output L
        move    b,x:(r7+$26)            ; parked for the chain's mono average
        move    x:(r7+$1b),a
        move    a,r5
        move    b,y:(r5)                ; -> shared DELAY OUTPUT, L
        move    y:>$090c,y1             ; print gain
        mpy     x0,y1,a                 ; (audited-signed x0,y1)
        asl     #$1,a,a
        move    x:(r0),b                ; dry L, still in place
        add     b,a                     ; + dry at unity (v5)
        move    a,x:(r0)                ; L in place -- dry + wet*MIX
        move    x:(r7+$33),x0           ; wet R = fR
        move    x0,a
        move    x0,b
        asr     #$1,b,b                 ; wet/2 -> x1.5, matching L
        add     b,a
        move    x:(r7+$2b),y1           ; PING
        mpy     x0,y1,b                 ; wet*PING (signed order)
        asr     #$1,b,b
        add     b,a                     ; + wet*PING/2
        asr     #$1,b,b
        add     b,a                     ; + wet*PING/4 -> R shelf 0.75*PING
        move    a,x0                    ; wet R, final
        move    x:(r7+$3c),y1           ; MIX
        mpy     x0,y1,a                 ; wet * MIX
        move    a,x0                    ; x0 = wet*MIX
        move    x:(r7+$25),b
        add     x0,b                    ; b = stage output R
        move    x:(r7+$1b),a
        add     #>$1,a
        move    a,r5
        move    b,y:(r5)                ; -> shared DELAY OUTPUT, R
        move    y:>$090c,y1             ; print gain, as on L
        mpy     x0,y1,a
        asl     #$1,a,a
        move    x:(r0+n0),x0            ; dry R
        add     x0,a
        move    a,x:(r0+n0)             ; R in place -- dry + wet*MIX
; ---- the CHAIN buffer: mono average of the stage output, at unity --------
        move    x:(r7+$26),a            ; out L
        add     b,a                     ; + out R (b still holds it)
        asr     #$1,a,a                 ; mono
        move    x:(r7+$3b),b            ; this call's CHAIN write address
        move    b,r5
        move    a,y:(r5)                ; CHAIN[write][i] = the stage output --
                                        ; a STORE, not an accumulate: one
                                        ; writer, and nobody clears this buffer
        move    x:(r7+$3b),a
        move    #>$1,x0
        add     x0,a
        move    a,x:(r7+$3b)            ; advance the CHAIN write pointer
        move    x:(r7+$1b),a
        add     #>$2,a
        move    a,x:(r7+$1b)            ; OUTPUT pointer: one stereo frame on

        move    (r0)+n0                 ; advance one stereo frame: two
        move    (r0)+n0                 ; steps, n0 stays 1 (14 Sep 2026)
dlyend:

; ---- save both phases, restore the M registers ----------------------------
        move    r1,a
        move    x:(r7+$22),x0           ; the L ring's mask ($7fff in REVERSE)
        and     x0,a
        move    a,x:(r7+$27)
        move    r2,a
        move    #>$3fff,x0
        and     x0,a
        move    a,x:(r7+$28)
dry:
        move    r7,a                    ; the r7 REBASE undone: the raw
        sub     #>$49,a                 ; state block goes back to the
        move    a,r7                    ; dispatcher exactly as it came
        move    #>$ffffff,m1            ; the global linear invariant for the
        move    #>$ffffff,m2            ; two pointers this file never sets
        rts

modtap:
        move    x:(r7+$2c),x0           ; TIME
        sub     x0,a
        move    x:(r7-$20),x0           ; mod_int, signed
        sub     x0,a
        move    x:(r7+$22),x0           ; the ring's mask ($3fff; $7fff in REVERSE)
        and     x0,a
        move    a1,x0
        move    x0,a                    ; A2-clean
        move    a,x:(r7-$1f)            ; park phase
        move    a,r5
        move    y:(r5+n5),a             ; t0 (n5 = the line base, from the caller)
        move    a,x:(r7-$1e)            ; t0
        move    x:(r7-$1f),a
        move    #>$1,x0
        sub     x0,a
        move    x:(r7+$22),x0
        and     x0,a                    ; one sample OLDER
        move    a1,r5                   ; the masked phase, no limiter in the way
        move    y:(r5+n5),a             ; t1
        move    x:(r7-$1e),x0
        sub     x0,a                    ; t1 - t0, signed
        move    a1,x0                   ; -> FIRST mpy operand
        move    x:(r7-$1d),y1           ; frac
        mpy     x0,y1,a
        move    x:(r7-$1e),x0
        add     x0,a                    ; tap = t0 + frac*(t1-t0)
        rts

satdrv:
        move    a,x:(r7-$1a)            ; park w. A LIMITING store: the sum
                                        ; can exceed full scale and a raw a1
                                        ; would WRAP where this saturates
        move    x:(r7-$1a),x0           ; w, saturated
        move    x0,y1
        mpy     x0,y1,b                 ; w^2   (signed x signed)
        move    b,y1                    ; limiting move: w^2 <= 1
        mpy     x0,y1,b                 ; w^3
        move    b,x0
        move    #>$2aaaab,y1            ; 1/3
        mpy     x0,y1,b                 ; w^3/3
        move    x:(r7-$1a),a            ; w
        move    b,x0
        sub     x0,a                    ; sat = w - w^3/3
        move    a,x:(r7-$19)
        move    x:(r7-$1c),b            ; DPTH (wow depth; zero iff knob is 0)
        tst     b
        move    x:(r7-$1a),a            ; w back (DPTH=0 keeps it)
        move    x:(r7-$19),x0           ; sat
        tne     x0,a

        move    a,y0                    ; live (the limiting copy applies the
                                        ; same clamp the line store would)
        move    y:>$0904,y1             ; r
        sub     x1,a                    ; live - tap
        asr     #$1,a,a                 ; /2 keeps the product path in range
        move    a,x0
        mpy     x0,y1,a                 ; r*(live-tap)/2  [audited-signed]
        asl     #$1,a,a
        add     x1,a                    ; v = tap + r*(live-tap)
        move    a,x1                    ; v (the tap is consumed)
        move    #>$7b7889,x0            ; g ~ 0.9646/call = 0.93/sample:
                                        ; r reaches 1% in ~64 samples, 1.5 ms
        mpy     x0,y1,b                 ; g*r
        move    b,x0                    ; decayed candidate
        move    x:(r7-$23),a            ; FREEZE flag
        tst     a
        move    y1,a                    ; running: r keeps its armed value
        tne     x0,a                    ; frozen: r decays
        move    a,y:>$0904
        move    y0,a                    ; live
        tne     x1,a                    ; frozen -> crossfaded hold (same Z:
                                        ; moves and Tcc do not disturb it)
        rts

smoothw:
        move    #$40,x0  
        sub     x0,a
        abs     a
        neg     a
        add     x0,a                    ; triangle, 0..$400000
        asl     #$1,a,a                 ; g, 0..1 (limiting move clamps the peak)
        move    a,x0
        move    a,y1
        mpy     x0,y1,a                 ; g^2
        move    a,x:(r7+$11)
        move    #>$7fffff,a
        sub     x0,a
        move    a,y1                    ; 1-g
        move    x:(r7+$11),x0
        mpy     x0,y1,a
        asl     #$1,a,a
        add     x0,a                    ; s = g^2*(3-2g)
        rts

