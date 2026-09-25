| usbaudio.s -- twenty channels over USB (UAC2): the eight tracks, post-FX
| pre-fader, from the read-back arena the eDMA fills every block (1-16),
| then MAIN L/R (17-18) and CUE L/R (19-20), the DAC feed (MC_BASE below).
| markandrus/octemu custom/coldfire/usb-audio.s at 6a9ff68 (MIT), carried
| as a DRAM unit of octabam's platform: the loader places and installs it,
| so his self-relocating entry, stage-2 hook installer, runtime patch table,
| card trampoline, page allocator, on-screen reporter and hook guard are
| not here -- every hook is a build-time detour of this module's manifest,
| the rings live in this unit's data, and the loader zeroes them. The
| shims, the EP3 bring-up and the UAC2 class-request replies are his text;
| the assembler constants his build passed as defsyms are the .set block
| below. modules/usbaudio/README.md has what was measured.
|
| octabam's changes to his stream (25 Sep 2026): 24-bit samples in 4-byte
| subslots where his carried 16-bit, polled every 250 us (bInterval 2) where
| his was every 500 us, four queue slots where his had two, and the dTDs and
| packet buffers in this unit's data, written through the uncached SDRAM
| alias, where his sat in a fixed 1,536-byte window at 0x4ec94a00. The
| producer, the packet builder's slot handling and the rate servo's units
| changed with them; his 16-bit text is in git history (6a9ff68).
| SPDX-License-Identifier: MIT
| usb-audio.s — the USB-audio payload, loaded from the CF card into flex-heap
| pages the firmware no longer believes exist (custom/usb-audio.py).
|
| Copied there at runtime by custom/coldfire/usb-audio-tramp.s, this holds
| everything too large for the image's free space: the four grown UAC2 config
| descriptors (generated into usb-audio-cfg.s by custom/usb-audio.py), the
| SET/GET_INTERFACE + EP0 clock-request + usb_isr + descriptor-clamp shims,
| and the EP3 iso packet builder that streams the eight tracks to the host as
| SIXTEEN channels at 44.1 kHz 16-bit (track 1 L/R on channels 1/2 ... track 8
| L/R on 15/16) at high speed, or their stereo sum at full speed.
|
| stage2 installs every image hook AT RUNTIME (expect-guarded, D-cache pushed
| and I-cache invalidated), so an image whose card lacks /USBAUDIO.BIN is the
| stock usb-midi composite and nothing here ever runs.
|
| defsyms from usb-audio.py: USBMIDI_ISR_SHIM (chain target), CFG_LEN (grown
| config length), MIDI_CFG_{FS,HS,OS_FS,OS_HS} (the usb-midi config addresses
| the responder's pea sites currently hold — the expect() values),
| UAC2_AC_IFACE / UAC2_AS_IFACE / UAC2_CLOCK_ID (the audio function's
| interface numbers and clock entity, shared with the descriptor generator).
| ---- the constants his build passed as --defsym / asmsyms ------------------
.set SUM_SHIFT,      8              | 32-bit read-back -> 24-bit units for the sum
.set UAC2_AC_IFACE,  3              | the audio function's AudioControl
.set UAC2_AS_IFACE,  4              | ... and its AudioStreaming
.set UAC2_CLOCK_ID,  0x10
.set AUD_SERVO,      1
.set AUD_SOURCE,     0              | the eight tracks
.set GUARD_SHIM,     0
.set EXPECT_BASE,    0
.set EXPECT_STAGE2,  0
.set GUARD_FRAME,    0
.set HEAP_RESERVE,   0
| The clamps are USB MIDI's (they read cfg_len, the descriptor unit's
| absolute symbol), and the ISR shim chains to USB MIDI's by symbol: the
| units link together, and this module's detour at 0x4001e606 stands in
| for USB MIDI's (schema.Override).


| ---- image sites (his disassembly of the usb-midi image) ----
.if AUD_SOURCE == 6
.set SRC_IS_TRACKS, 1
.elseif AUD_SOURCE == 0
.set SRC_IS_TRACKS, 1
.else
.set SRC_IS_TRACKS, 0
.endif
.set SETUP_ALT,      0x46c8ce0a     | SETUP wValue low = alt setting
.set SETUP_IFACE,    0x46c8ce0c     | SETUP wIndex low = interface number
.set EP0_STATUS_IN,  0x4001d524     | zero-length EP0 IN status (ACK)
.set SETIFACE_DONE,  0x4001de74     | control-request-done
.set SETIFACE_STOCK, 0x4001dd0a     | rejoin after the displaced movel
.set GETIFACE_REJOIN,0x4001d81e     | GET_INTERFACE send tail (expects pea'd ptr)
.set GETIFACE_STOCKP,0x400e20a1     | the stock 1-byte "00" the send reads
.set CLAMP1_REJOIN,  0x4001d864     | after the CONFIG length clamp
.set CLAMP2_REJOIN,  0x4001d8a2     | after the OTHER_SPEED length clamp
.set SETUP_BMREQ,    0x46c8ce08     | SETUP bmRequestType
.set SETUP_BREQ,     0x46c8ce09     | SETUP bRequest
.set SETUP_WVALH,    0x46c8ce0b     | SETUP wValue high = control selector
.set SETUP_WIDXH,    0x46c8ce0d     | SETUP wIndex high = entity id
.set EP0_SEND_TAIL,  0x4001de5c     | jsr usb_ep0_send(len, buf); addq; done
.set CTRL_STOCK,     0x4001de6a     | the stock STALL, after the displaced movel

| ---- USB controller registers ----
.set EPLISTADDR, 0xfc0b0158         | the controller's OWN dQH list base
.set ENDPTSTAT,  0xfc0b01b8
.set DCCPARAMS,  0xfc0b0124         | DEN[4:0] = endpoint pairs this core has
.set USBSTS,     0xfc0b0144
.set USBINTR,    0xfc0b0148
.set EPPRIME,    0xfc0b01b0
.set EPFLUSH,    0xfc0b01b4
.set EPCOMPLETE, 0xfc0b01bc
.set ENDPTCTRL3, 0xfc0b01cc
.set USBCMD,     0xfc0b0140
.set ATDTW,      0x00004000         | USBCMD bit 14: the add-dTD tripwire
.set QH_EP3IN,   0x4ec949c0         | EP3 IN dQH as OBSERVED IN THE EMULATOR.
                                    | ☠ Only ever a fallback now. The real base
                                    | is read from ENDPTLISTADDR at run time:
                                    | hardcoding it assumed the firmware puts
                                    | its endpoint list where QEMU showed it,
                                    | and if silicon differs the controller
                                    | never sees our queue head at all -- which
                                    | presents as an endpoint that enumerates
                                    | and then transmits nothing, forever.
.set QH_EP3IN_OFF, 7*64             | EP3 IN is list entry (3*2)+1
.set EP3IN_BIT,  0x00080000         | ENDPTPRIME/STAT/COMPLETE bit for EP3 IN

| ---- the audio source: the post-FX readback arena, which EXISTS ON HARDWARE -
| ☠ This used to read a ring that only `-M octatrack,audio-tap=on` ever wrote
| (QEMU mirroring the DSP's ESAI TX, which no CPU on a real board can see). A
| unit running that build had no producer at all. The source here is
| readback_buf: the eDMA deposits every track's post-FX, pre-fader block into
| SRAM each frame, on silicon as in the emulator, and it is the same memory
| the RECEIVE machine sums — confirmed working on real hardware.
|
| Layout: RB_BASE + prev*1024 + track*128 + frame*8, two 32-bit words (L,R)
| per frame, 16 frames per block, 8 tracks. Reads use the PREVIOUS bank
| (the pipeline is one block deep).
|
| The arena holds the eight tracks SEPARATELY and the stream carries them that
| way: one stereo pair per track. Measured, not assumed — with the fixture's
| SINE440 trigged on track 1, `OCTA_RB_LOG=1` shows slot 0 peaking at 2.7e8
| while tracks 2-8 hold a constant idle 768, in both ping-pong banks.
|
| ☠ Every pair is PRE-FADER: track level, the crossfader and MAIN volume are
| downstream of it, and the master track's processing happens inside the DSP
| where no CPU can read it. These are the tracks' post-FX signals, not a
| recording of what the MAIN jacks emit.
|
| ☠ A track whose machine is RECEIVE carries whatever that machine is summing,
| not a signal of its own — that is the routing the user asked for, and it is
| what the arena holds.
.set FLEX_FREE_BASE, 0x8000691c     | live free-stack base cursor (index)
.set RB_BASE,      0x80003190
.set RB_PREV,      0x800000e4      | pingpong_prev: reads use prev
.set RB_TRACKS,    8
| MAIN and CUE: the DAC feed itself. Core 0's mixdown packs ESAI TX slots
| 2/3 and 0/1 (P:0x2df, P:0x2e2) into the host read-back after the track
| blocks; the frame ISR's chain ch1 -> ch6 -> ch7 lands them here, ch6
| writing 0x80005e60..0x80005f60 each frame: 16 x (L,R) at +0x00, then
| 16 x (L,R) at +0x80, 32-bit words in the read-back's format (24 bits,
| left-justified). The stock recorder reads the same buffer for SRC3 =
| MAIN (+0x00) / CUE (+0x80) from inside frame_isr (0x4000d2a0), before
| this hook; the next frame's ch6 cannot overwrite it until the next
| frame_isr. Single buffer, no ping-pong. MAIN = +0x00, CUE = +0x80:
| confirmed on hardware (Bryan's MKII, image 90, 25 Sep 2026).
.set MC_BASE,      0x80005e60
.set MC_MAIN_OFF,  0x00
.set MC_CUE_OFF,   0x80

| x -> x * SLOT_BYTES (80) in place; \t is scratch.
.macro MUL_SLOT r, t
    movel   \r,\t
    lsll    #4,\t                  | x * 16
    lsll    #6,\r                  | x * 64
    addl    \t,\r                 | x * 80
.endm

| ---- frame geometry --------------------------------------------------------
| The producer fills TWO rings per frame: an 80-byte slot (20 channels, each a
| 4-byte little-endian subslot carrying 24 bits: track 1 L/R first, track 8
| L/R on 15/16, then MAIN L/R on 17/18 and CUE L/R on 19/20) for the HIGH
| SPEED stream, and an 8-byte stereo sum of the eight
| tracks for FULL SPEED. Both are indexed by the same frame count, so the
| wrap arithmetic has one form.
|
| A track's sample is the read-back word with its low byte cleared: the
| arena's full scale is 2^31 (his 16-bit calibration kept the top 16 bits),
| so the subslot's 24 valid bits are the arena's top 24 at the same scale.
|
| ☠ Why the poll is 250 us: 20 ch x 4 B at 44.1 kHz is 3,528 B per
| millisecond, and one high-speed isochronous transaction carries at most
| 1,024 B. At bInterval 2 a packet is 11.025 frames x 80 B = 882 B, at most
| 12 frames = 960 B with the servo (20 ch x 4 B; 16 ch was 64 B / 768 B).
| Full speed carries the stereo sum only:
| 44.1 frames x 8 B = 353 B per 1 ms frame, under the 1,023 B cap. UAC1
| cannot poll faster than 1 ms even at high speed (Apple TN3190: bInterval
| must be 4); this is why the descriptors are UAC2.
.set SLOT_BYTES,   80           | ring slot: 8 tracks * (L,R) + MAIN (L,R) + CUE (L,R), 4 B each
                                | ☠ not a power of two: index math is MUL_SLOT (x*64 + x*16)
.set SUM_BYTES,    8            | sum slot: (L,R) * 4 B
.set PKT_MAX_HS,   12*SLOT_BYTES | 960: the largest 250 us packet (<= 1,024 B, one transaction)
.set PKT_MAX_FS,   45*SUM_BYTES | 360: the largest 1 ms stereo packet
.set STEP_HS,      11025        | 11.025 frames per 250 us packet, x1000
.set STEP_FS,      44100        | 44.1 frames per 1 ms packet, x1000
.set SERVO_STEP,   100          | +-0.1 frame per packet, x1000

| ☠ FOUR queue slots, so the host always finds a packet waiting: four
| packets cover 1 ms of polls, the same cover his two covered at 500 us.
| The frame ISR (every 363 us) is the only context that queues, so the
| queue must outlast one block plus that interrupt's latency.
.set NSLOT,        4            | power of two: slot arithmetic is a mask
.set UNCACHED,     0x08000000   | + an SDRAM address = the same memory,
                                | cache-inhibited (PLACEMENT.md)

| The payload's own audio rings. They live in the unit's data and are zeroed
| by the loader. 1024 frames — 23 ms of buffer, ample between a ~2756/s
| producer and a 4 kHz consumer. ☠ Only the CPU ever reads the rings, through
| their cached addresses — the USB controller reads the packet buffers — so
| the rings need no cache maintenance at all.
.set AUD_FRAMES,   1024
.set AUD_TARGET,   512          | ring fill the stream starts at and the servo
                                    | steers towards: ~12 ms, enough that a
                                    | momentary producer stall is absorbed
                                    | rather than becoming a dropout. This
                                    | stream is for recording; latency here
                                    | costs nothing.
.set AUD_BAND,     128          | servo deadband, so it does not hunt

.set CACR_ICINVA,  0xa40ce100       | steady-state CACR + ICINVA (FREE-SPACE.md)
.set PORTSC1,    0xfc0b0184         | bits 27:26 = port speed, 2 = high
| The firmware's own device attach/detach — usb_attach(1) attaches,
| usb_attach(0) detaches; USB DISK MODE uses it on entry and exit.
.set USB_ATTACH,   0x4001eb44

    .text
| ---- SET_INTERFACE shim (installed at 0x4001dd04) ---------------------------
| Displaced: movel 0xfc0b01c4,%d0. Interface 4 (AudioStreaming) records the
| requested alt setting and completes the status stage; any other interface
| falls through to the stock handler unchanged.
|
| ☠ The shim RECORDS the request. Everything that builds EP3 state — the
| queue head, the dTDs, ENDPTCTRL3, the ring cursors — is done by the frame
| ISR (audio_ep3_up / audio_ep3_down), the one context that also queues
| packets. This runs from the USB interrupt; if it re-initialized the
| endpoint itself, a SET_INTERFACE landing in the middle of a kick would
| rewrite a queue the kick was still building, and the kick would then prime
| the remains. One owner, one byte of shared state.
|
| The one exception is alt 0's FLUSH, done here as well: the host may send
| its next IN within microseconds of the status stage, before the frame ISR
| has had its block, and a packet already queued would answer it — audio
| after teardown. A flush only cancels what is in flight, is idempotent, and
| builds nothing, so it is safe from this context; the kick checks the
| request byte before it queues, so nothing new follows it; and the frame
| ISR flushes again on its way down. (The audio-alt gate asserts silence
| after alt 0, and caught the deferred-only version.)
|
| ☠ Interrupt levels, from the firmware's own INTC writes: the USB interrupt
| is INTC1 source 47 at level 4 (moveq #4 / moveb ->0xfc04c06f at
| 0x4001e024); the frame IRQ is EPORT IRQ1 at level 5 (0x4001fc30). So the
| frame ISR can preempt this shim — harmless, it only ever sees the request
| byte — but this shim can NEVER interrupt a kick. The single-owner rule is
| belt and braces over that fact, not a substitute for it.
    .global audio_setiface_shim
audio_setiface_shim:
    mvzb    SETUP_IFACE,%d0
    moveq   #UAC2_AS_IFACE,%d1
    cmpl    %d0,%d1
    bne     5f                      | not the AudioStreaming interface -> stock
    mvzb    SETUP_ALT,%d0
    tstl    %d0
    beqs    2f
    moveq   #1,%d0                  | any non-zero alt is the streaming one
    moveb   %d0,usbaudio_alt        | the request; the frame ISR brings EP3 up
    bras    3f
2:  clrb    usbaudio_alt            | the request FIRST: no kick queues past it
    bsr     audio_ep3_flush         | then cancel what is already queued
3:  jsr     EP0_STATUS_IN
    jmp     SETIFACE_DONE
5:  movel   0xfc0b01c4,%d0          | displaced
    jmp     SETIFACE_STOCK

| ---- GET_INTERFACE shim (installed at 0x4001d824) ---------------------------
| Displaced: pea 0x400e20a1 (the stock 1-byte "00"). Interface 4 reports the
| alt setting the host asked for (whether or not the frame ISR has acted on it
| yet, which it does within one block); every other interface keeps the stock
| answer.
    .global audio_getiface_shim
audio_getiface_shim:
    mvzb    SETUP_IFACE,%d0
    moveq   #UAC2_AS_IFACE,%d1
    cmpl    %d0,%d1
    bnes    1f
    pea     usbaudio_alt
    jmp     GETIFACE_REJOIN
1:  pea     GETIFACE_STOCKP
    jmp     GETIFACE_REJOIN

| ---- EP0 buffer-page fix (installed at 0x4001d4b2 inside usb_ep0_send) -------
| ☠ usb_ep0_send sets only the dTD's buffer PAGE 0 (0x4ec95028), never PAGE 1.
| A descriptor whose buffer crosses a 4 KB page then transmits only the bytes
| before the boundary and zeros after. The grown UAC2 config straddles a page
| once the payload relocates into a heap page (the shipping load path), so the
| FULL-SPEED config truncated to the stock 32-byte MSC part. This shim also
| fills PAGE 1 = (buffer & ~0xfff) + 0x1000, so any EP0 descriptor send that
| spans a page boundary completes. It is load-address independent — the fix a
| page-safe placement could only approximate.
|
| Displaced: movel %a0@,0x4ec95028 (a0 = &buffer-arg, set by the preceding
| lea %sp@(12),%a0); rejoin at the following lea (0x4001d4b8). %d0 is dead
| across the rejoin (reloaded at 0x4001d4da), so clobbering it is safe.
    .global audio_ep0page_shim
audio_ep0page_shim:
    movel   %a0@,%d0               | the descriptor buffer pointer (arg)
    movel   %d0,0x4ec95028         | dTD buffer page 0 (displaced instruction)
    andil   #0xfffff000,%d0
    addil   #0x1000,%d0
    movel   %d0,0x4ec9502c         | dTD buffer page 1 — the fix
    jmp     0x4001d4b8

| ---- usb_isr shim (installed at 0x4001e606, was jmp usbmidi_isr_shim) -------
| Services the block-clock SOF (kick the builder) and EP3 IN completions (free
| the dTD, kick again), then chains to the usb-midi ISR shim which handles EP2
| and runs the original displaced instruction.
    .global audio_isr_shim
audio_isr_shim:
    lea     %sp@(-8),%sp
    moveml  %d0-%d1,%sp@            | all this shim touches
    | ☠ Exactly ONE place queues packets on EP3: the per-block producer in
    | frame_isr. This shim only retires the completion bit so it cannot go
    | stale; the queue's own state is the ACTIVE bit of each dTD, which the
    | controller clears itself, so there is no bookkeeping to race on. The
    | dTDs are queued WITHOUT IOC — 2000 completion interrupts a second buy
    | nothing when nobody needs to be told.
    movel   EPCOMPLETE,%d0
    movel   #EP3IN_BIT,%d1
    andl    %d1,%d0
    beqs    2f
    movel   #EP3IN_BIT,%d1
    movel   %d1,EPCOMPLETE          | W1C EP3 IN
2:  moveml  %sp@,%d0-%d1
    lea     %sp@(8),%sp
    jmp     usbmidi_isr_shim         | USB MIDI's shim, whose detour this one stands in for

| ---- the iso packet builder -------------------------------------------------
| Each packet holds the next n frames from the ring: n = 11/12 at high speed
| (11025/1000 per packet) or 44/45 at full speed (44100/1000), so the emitted
| stream is an exact, gap-free substring of what the producer wrote. Underrun
| queues nothing (the host's IN gets an empty packet); a producer that laps
| the ring (host stopped draining) resyncs and counts an overrun.
| Runs from the frame shim only; may clobber every register but %sp.
|
| ☠ An isochronous IN cannot NAK: an IN token that arrives with nothing
| primed is answered with a zero-length packet, and a hole in the stream is a
| click. The frame ISR keeps up to NSLOT packets queued and the controller
| chains from one to the next on its own. (An earlier two-deep attempt of his
| wedged against the bench, which walked linked iso dTDs as one bulk
| transfer; the bench serves one dTD per poll, as silicon does.)
|
| The slots are used in turn: aud_tail is the next to fill, so fill order is
| tail-3, tail-2, tail-1 (oldest to newest) and the controller retires them
| in that order. A slot whose dTD is still ACTIVE is in flight or queued and
| is left alone.
usbaudio_kick:
    tstb    usbaudio_alt            | alt 0 requested since this block began:
    beqs    9f                      | queue nothing more (teardown follows)
    moveq   #NSLOT,%d0
    movel   %d0,%sp@-               | builds left this block
1:  bsr     audio_pkt_build         | fill the tail slot, if free
    tstl    %d0
    beqs    2f
    subql   #1,%sp@
    bnes    1b
2:  addql   #4,%sp
    | ☠ Self-heal. The add-dTD tripwire (audio_pkt_build) is the documented
    | way to append to a running queue, and its hazard window is reported by
    | the hardware clearing ATDTW. Should anything ever leave an ACTIVE dTD
    | behind with the endpoint idle — a missed hazard, a flush that raced a
    | prime — the stream would otherwise stall until the next alt 0/1. So
    | every block ends with: idle endpoint + queued dTD = prime the oldest,
    | and count it, so a silent recovery is still measurable.
    movel   ENDPTSTAT,%d0
    movel   EPPRIME,%d1
    orl     %d1,%d0
    andil   #EP3IN_BIT,%d0
    bnes    9f                      | primed or priming: running
    mvzb    aud_tail,%d2            | oldest first: fill order from the tail
    bsr     audio_oldest
    tstl    %d0
    beqs    9f                      | nothing queued: idle is correct
    bsr     audio_prime             | %a4 = head dTD
    addql   #1,usbaudio_reprimes
9:  rts

| %d0 = slot index (taken mod NSLOT) -> %a0 = its dTD, through the uncached
| alias. Clobbers d0.
audio_dtd_of:
    andil   #NSLOT-1,%d0
    lsll    #5,%d0
    moveal  #(aud_dtds+UNCACHED),%a0
    addal   %d0,%a0
    rts

| The oldest queued dTD: the first ACTIVE one from slot %d2 onward, in fill
| order. Returns d0 = 1 and %a4 = it, or d0 = 0 when none is ACTIVE.
| Clobbers d0-d3/a0.
audio_oldest:
    moveq   #NSLOT-1,%d3
1:  movel   %d2,%d0
    bsr     audio_dtd_of
    movel   %a0@(4),%d1
    btst    #7,%d1
    bnes    2f
    addql   #1,%d2
    subql   #1,%d3
    bpls    1b
    moveq   #0,%d0
    rts
2:  moveal  %a0,%a4
    moveq   #1,%d0
    rts

| Point the queue head at %a4 and prime EP3 IN — the "list empty" case of the
| Chipidea add-dTD procedure. Clobbers d0/a1.
audio_prime:
    moveal  qh_ep3,%a1
    movel   %a4,%a1@(8)             | dQH next dTD
    clrl    %a1@(12)                | dQH token: ACTIVE/HALT clear before a prime
    movel   #EP3IN_BIT,%d0
    movel   %d0,EPPRIME
    rts

| Build one packet into the tail slot and queue it. Returns d0 = 1 if a packet
| was queued, 0 if the slot was busy or the ring could not fill one.
audio_pkt_build:
    mvzb    aud_tail,%d0
    moveal  %d0,%a6                 | a6 = slot index, kept across the copy
    bsr     audio_dtd_of            | a0 = this slot's dTD
    movel   %a0@(4),%d1
    btst    #7,%d1                  | ACTIVE: in flight or queued
    bne     .Lpb_none
    tstb    usbaudio_alt            | (re-checked per packet: alt 0 can land
    beq     .Lpb_none               |  between two builds in one block)
    movel   aud_produced,%d0
    movel   usbaudio_consumed,%d1
    movel   %d0,%d2
    subl    %d1,%d2                 | d2 = frames available
    cmpil   #AUD_FRAMES,%d2
    blss    3f                      | within the ring: fine
    addql   #1,usbaudio_overruns
    movel   %d0,%d1
    subil   #AUD_FRAMES,%d1
    movel   %d1,usbaudio_consumed   | resync to the ring's trailing edge
    movel   #AUD_FRAMES,%d2
3:  movel   usbaudio_acc,%d3
    | ☠ RATE SERVO. The endpoint is ASYNCHRONOUS: the device sends at its own
    | clock and the host adapts. The host's polls run on ITS clock, so a fixed
    | 11.025 frames per poll would drain the ring faster or slower than the
    | producer fills it, by the two clocks' drift, and the ring would under-
    | or overrun within minutes. The servo nudges the drain by +-0.1 frame per
    | packet against a target fill, which is exactly "send what is produced".
    | AUD_SERVO 0 disables it, for A/B measurement only.
    movel   aud_step,%d5            | nominal frames per packet, x1000
    .if AUD_SERVO == 0
    bras    .Lsrv_done
    .endif
    cmpil   #(AUD_TARGET+AUD_BAND),%d2
    bcss    .Lsrv_low
    addil   #SERVO_STEP,%d5
    bras    .Lsrv_done
.Lsrv_low:
    cmpil   #(AUD_TARGET-AUD_BAND),%d2
    bccs    .Lsrv_done
    subil   #SERVO_STEP,%d5
.Lsrv_done:
    addl    %d5,%d3
    movel   #1000,%d7
    movel   %d3,%d4
    divu.l  %d7,%d4                 | d4 = n = (acc+step)/1000
    movel   %d4,%d5
    mulu.l  %d7,%d5
    movel   %d3,%d6
    subl    %d5,%d6                 | d6 = new acc
    cmpl    %d4,%d2
    bccs    .Lhave_frames
    addql   #1,usbaudio_underruns
    bra     .Lpb_none               | available < n: underrun, send nothing
.Lhave_frames:
    movel   %d6,usbaudio_acc
    movel   %d4,usbaudio_lastn
    movel   %d2,usbaudio_lastfill
    | ---- copy n frames into this slot's buffer -----------------------------
    | a3 = the buffer (aud_bufs + slot * 960, through the uncached alias),
    | a1 = write cursor. The ring is copied in at most two straight runs (up
    | to its end, then from its start), with no per-frame index masking.
    movel   %a6,%d0
    lsll    #8,%d0
    lsll    #2,%d0                  | slot * 1024
    movel   %a6,%d1
    lsll    #6,%d1                  | slot * 64
    subl    %d1,%d0                 | slot * 960 = slot * PKT_MAX_HS
    moveal  #(aud_bufs+UNCACHED),%a3
    addal   %d0,%a3
    moveal  %a3,%a1
    movel   %d4,%d3                 | d3 = n
    movel   usbaudio_consumed,%d1
    andil   #AUD_FRAMES-1,%d1       | ring index of the first frame
    movel   #AUD_FRAMES,%d0
    subl    %d1,%d0                 | d0 = frames before the ring wraps (>= 1)
    tstb    aud_hs
    beqs    .Lcopy_fs
    lea     aud_ring,%a2
    MUL_SLOT %d1, %d2               | d2 is dead here (lastfill is stored)
    addal   %d1,%a2                 | a2 = the first frame's slot
    cmpl    %d0,%d3
    bhis    .Lhs_wrap               | n > frames to the end: two runs
    movel   %d3,%d0
    bsr     audio_copy80
    bras    .Lcopied
.Lhs_wrap:
    subl    %d0,%d3
    moveal  %d3,%a5                 | a5 = frames in the second run (the copy
    bsr     audio_copy80            |      clobbers every data register)
    lea     aud_ring,%a2
    movel   %a5,%d0
    bsr     audio_copy80
    bras    .Lcopied
.Lcopy_fs:
    lea     aud_sum,%a2
    lsll    #3,%d1
    addal   %d1,%a2
    cmpl    %d0,%d3
    bhis    .Lfs_wrap
    movel   %d3,%d0
    bsr     audio_copy8
    bras    .Lcopied
.Lfs_wrap:
    subl    %d0,%d3
    moveal  %d3,%a5
    bsr     audio_copy8
    lea     aud_sum,%a2
    movel   %a5,%d0
    bsr     audio_copy8
.Lcopied:
    movel   usbaudio_lastn,%d4      | n again (the copy clobbered it)
    addl    %d4,usbaudio_consumed
    movel   %d4,%d6
    tstb    aud_hs
    beqs    5f
    MUL_SLOT %d6, %d1               | nbytes = n * 80 (d1 is reloaded below)
    bras    6f
5:  lsll    #3,%d6                  | nbytes = n * 8
6:  | ---- the dTD: buffer pointers first, the ACTIVE token LAST -------------
    | The dTD and the buffer are written through the uncached alias, so these
    | stores reach memory in program order: the controller cannot see an
    | ACTIVE token over a half-built descriptor or a half-copied buffer.
    moveq   #1,%d1
    movel   %d1,%a0@                | next = terminate
    movel   %a3,%a0@(8)             | buffer page 0
    movel   %a3,%d1
    andil   #0xfffff000,%d1
    addil   #0x1000,%d1
    movel   %d1,%a0@(12)            | page 1: a 960-byte buffer can straddle a 4 KB page
    movel   %d6,%d1
    swap    %d1                     | nbytes << 16
    oril    #0x80,%d1               | ACTIVE (no IOC: completions buy nothing)
    movel   %d1,%a0@(4)
    | ---- queue it: the Chipidea "add dTD" procedure -------------------------
    | Case 1, list empty (the previous slot in fill order is not ACTIVE, so
    | nothing older is either): point the queue head at this dTD and prime.
    | Case 2, list running: link this dTD after the previous one, then the
    | tripwire — set ATDTW, sample ENDPTSTAT, trust the sample only if ATDTW
    | is still set (hardware clears it when the sample fell in its hazard
    | window). Still primed: the controller follows the link by itself. Not
    | primed: it retired the previous dTD before it saw the link, so the HEAD
    | to prime is the oldest dTD still ACTIVE (never skip a queued packet),
    | which is this one if every other has retired.
    moveal  %a0,%a4                 | a4 = the head to prime, if it comes to that
    moveal  %a0,%a5                 | a5 = this dTD (audio_dtd_of returns in a0)
    movel   %a6,%d0
    subql   #1,%d0
    bsr     audio_dtd_of
    moveal  %a0,%a2                 | a2 = the previous slot's dTD
    moveal  %a5,%a0
    movel   %a2@(4),%d0
    btst    #7,%d0
    beqs    .Lenq_prime             | case 1
    movel   %a0,%a2@                | case 2: previous.next = this
    movel   EPPRIME,%d0
    andil   #EP3IN_BIT,%d0
    bnes    .Lenq_done              | a prime is pending: it will read the list
    moveq   #16,%d2                 | tripwire attempts (bounded: this is an ISR)
.Lenq_trip:
    movel   USBCMD,%d0
    oril    #ATDTW,%d0
    movel   %d0,USBCMD
    movel   ENDPTSTAT,%d1
    andil   #EP3IN_BIT,%d1          | the sample
    movel   USBCMD,%d0
    andil   #ATDTW,%d0
    bnes    .Lenq_sampled
    subql   #1,%d2
    bnes    .Lenq_trip              | hazard: the sample is void, take another
    bras    .Lenq_done              | never settled: assume running; the
.Lenq_sampled:                      | self-heal re-primes next block if not
    movel   USBCMD,%d0
    andil   #0xffffbfff,%d0         | ~ATDTW
    movel   %d0,USBCMD
    tstl    %d1
    bnes    .Lenq_done              | still running: it will follow the link
    movel   %a6,%d2
    addql   #1,%d2                  | oldest first: tail+1 .. tail in fill order
    bsr     audio_oldest            | a4 = the oldest ACTIVE (this one at worst)
.Lenq_prime:
    bsr     audio_prime
.Lenq_done:
    movel   %a6,%d0
    addql   #1,%d0
    andil   #NSLOT-1,%d0
    moveb   %d0,aud_tail            | the next slot fills next
    moveq   #1,%d0
    rts
.Lpb_none:
    moveq   #0,%d0
    rts

| Copy d0 (>= 1) 64-byte frames from %a2 to %a1, both advanced: two moveml
| pairs per frame. Clobbers d1-d7/a4.
audio_copy80:
1:  moveml  %a2@,%d1-%d7/%a4
    moveml  %d1-%d7/%a4,%a1@
    moveml  %a2@(32),%d1-%d7/%a4
    moveml  %d1-%d7/%a4,%a1@(32)
    moveml  %a2@(64),%d1-%d4
    moveml  %d1-%d4,%a1@(64)
    lea     %a2@(80),%a2
    lea     %a1@(80),%a1
    subql   #1,%d0
    bnes    1b
    rts

| Copy d0 (>= 1) 8-byte stereo-sum frames from %a2 to %a1, both advanced.
audio_copy8:
1:  movel   %a2@+,%a1@+
    movel   %a2@+,%a1@+
    subql   #1,%d0
    bnes    1b
    rts

| Mark the queue idle: zero every dTD (ACTIVE clear, next = terminate) and
| start filling at slot 0. Written through the uncached alias, so no cpushl.
| Clobbers d0/d1/a1.
audio_dtds_clear:
    moveal  #(aud_dtds+UNCACHED),%a1
    moveq   #NSLOT*8-1,%d1
1:  clrl    %a1@+
    subql   #1,%d1
    bpls    1b
    moveal  #(aud_dtds+UNCACHED),%a1
    moveq   #1,%d0
    moveq   #NSLOT-1,%d1
2:  movel   %d0,%a1@                | next = terminate
    lea     %a1@(32),%a1
    subql   #1,%d1
    bpls    2b
    clrb    aud_tail
    rts

| Resolve EP3's queue head from ENDPTLISTADDR. Returns it in %a0 and caches it
| in qh_ep3. ☠ VALIDATE BEFORE TRUSTING: stage2 runs during the card poll,
| early enough that the controller need not be set up, so this register can
| hold power-on garbage. The firmware programs 0x4EC94800 here; anything
| outside SDRAM is not an endpoint list and the known-good constant is used.
audio_qh_resolve:
    movel   EPLISTADDR,%d0
    andil   #0xfffff800,%d0
    cmpil   #0x40000000,%d0
    blts    .Lqh_fallback
    cmpil   #0x50000000,%d0
    bges    .Lqh_fallback
    bras    .Lqh_have
.Lqh_fallback:
    movel   #(QH_EP3IN - QH_EP3IN_OFF),%d0
.Lqh_have:
    addil   #QH_EP3IN_OFF,%d0
    movel   %d0,qh_ep3
    moveal  %d0,%a0
    rts

| ---- EP3 bring-up / teardown: frame-ISR context ONLY ------------------------
| The SET_INTERFACE shim records the host's request in usbaudio_alt; the frame
| shim compares it with aud_running once per block and calls one of these.
| Everything EP3 — queue head, dTDs, ENDPTCTRL3, ring cursors — is owned by
| that one context, so nothing here can interleave with a kick.
audio_ep3_up:
    | ☠ FLUSH FIRST. A dTD left primed by an earlier session must not be in
    | flight while the queue head is rewritten underneath it.
    bsr     audio_ep3_flush
    | ☠ ZERO THE WHOLE 64-BYTE dQH. EP3's queue head sits past anything the
    | stock firmware ever initializes, so on hardware its TOKEN (+0x0C) and
    | buffer pointers (+0x10..+0x1C) hold power-on garbage. The device
    | controller is a real bus master on silicon: it acts on that token's
    | ACTIVE bit and those pointers, then writes transfer status back through
    | them — an arbitrary memory write, which lands wherever the garbage
    | points (image code included). The firmware's own EP0 setup at
    | 0x4001d656 clears the token for exactly this reason; clearing the whole
    | structure is the safe superset. QEMU's packet bench never showed this
    | because it does not fetch the dQH out of guest memory at all.
    bsr     audio_qh_resolve        | %a0 = EP3 dQH, from the controller
    moveq   #15,%d1
1:  clrl    %a0@+
    subql   #1,%d1
    bpls    1b
    moveal  qh_ep3,%a0              | resolved just above
    | ☠ The SPEED decides the stream: 20 channels in <= 960 B packets every
    | 250 us at high speed, the stereo sum in <= 360 B packets every 1 ms at
    | full speed. PORTSC1 bits 27:26 are the negotiated speed (2 = high); the
    | responder picks the config descriptor by the same bits, so the format
    | the host was told and the packets it gets cannot disagree.
    movel   PORTSC1,%d0
    lsrl    #8,%d0
    lsrl    #8,%d0
    lsrl    #8,%d0
    lsrl    #2,%d0
    andil   #3,%d0
    cmpil   #2,%d0
    bnes    .Lspeed_fs
    moveq   #1,%d0
    moveb   %d0,aud_hs
    movel   #STEP_HS,%d0
    movel   %d0,aud_step
    movel   #(0x60000000+(PKT_MAX_HS<<16)),%d0  | dQH cap: Mult 1, ZLT off, maxpkt 960
    bras    .Lspeed_set
.Lspeed_fs:
    clrb    aud_hs
    movel   #STEP_FS,%d0
    movel   %d0,aud_step
    movel   #(0x60000000+(PKT_MAX_FS<<16)),%d0  | Mult 1, ZLT off, maxpkt 360
.Lspeed_set:
    movel   %d0,%a0@
    clrl    %a0@(4)                 | current dTD
    moveq   #1,%d0
    movel   %d0,%a0@(8)             | no dTD primed yet (terminate)
    clrl    %a0@(12)                | TOKEN — the field the firmware clears
    bsr     audio_dtds_clear        | both queue slots idle
    movel   #0x00840000,%d0         | ENDPTCTRL3: TXE + isochronous (the bench
    movel   %d0,ENDPTCTRL3          | reads the type to serve one dTD per poll)
    movel   aud_produced,%d0
    subil   #AUD_TARGET,%d0         | start a full cushion BEHIND the producer:
    bccs    .Lcons_ok               | the ring is already full, so there is no
    moveq   #0,%d0                  | priming gap and no startup underruns
.Lcons_ok:
    movel   %d0,usbaudio_consumed
    clrl    usbaudio_acc
    moveq   #1,%d0
    moveb   %d0,aud_running
    rts

audio_ep3_down:
    | ☠ FLUSH the endpoint. Clearing ENDPTCTRL3 disables it but does NOT
    | cancel a dTD that is already primed, so a packet queued microseconds
    | before alt 0 would still go out and the host would see audio after
    | teardown — intermittent by nature, which is why it first showed up as a
    | flaky gate rather than a clean failure.
    bsr     audio_ep3_flush
    clrl    ENDPTCTRL3
    bsr     audio_dtds_clear        | a flushed dTD still reads ACTIVE
    clrb    aud_running
    rts

| Flush EP3 IN and wait for it. ☠ The documented Chipidea sequence, not a
| single write: a prime that lands while a flush is in progress survives it,
| so after ENDPTFLUSH clears, ENDPTSTAT is checked and the flush repeated
| while the endpoint still shows primed. Bounded, because this runs in the
| frame ISR and a controller that never answers must not wedge the machine.
| Clobbers d0/d1.
audio_ep3_flush:
    moveq   #16,%d1                 | attempts
1:  movel   #EP3IN_BIT,%d0
    movel   %d0,EPFLUSH
2:  movel   EPFLUSH,%d0             | complete when the bit clears
    andil   #EP3IN_BIT,%d0
    bnes    2b
    movel   ENDPTSTAT,%d0
    andil   #EP3IN_BIT,%d0
    beqs    3f                      | idle: done
    subql   #1,%d1
    bnes    1b
3:  rts

    .if AUD_SOURCE == 6
| d1 = frame index 0..15 -> d2 = the telemetry field for that frame (diagnostic
| --source telem only). ☠ Must not touch d3 (the live right-channel sum).
audio_telem_value:
    moveq   #0,%d2
    tstl    %d1
    bnes    .Ltv1
    movel   #0x5A5A,%d2
    rts
.Ltv1:
    cmpil   #1,%d1
    bnes    .Ltv2
    movel   usbaudio_overruns,%d2
    lsrl    #8,%d2
    lsrl    #8,%d2
    bra     .Ltvdone
.Ltv2:
    cmpil   #2,%d1
    bnes    .Ltv3
    movel   usbaudio_overruns,%d2
    bra     .Ltvdone
.Ltv3:
    cmpil   #3,%d1
    bnes    .Ltv5
    movel   usbaudio_underruns,%d2
    bra     .Ltvdone
.Ltv5:
    cmpil   #5,%d1
    bnes    .Ltv6
    movel   usbaudio_lastfill,%d2
    bra     .Ltvdone
.Ltv6:
    cmpil   #6,%d1
    bnes    .Ltvdone
    movel   usbaudio_lastn,%d2
.Ltvdone:
    andil   #0x7fff,%d2
    rts
    .endif

    .if AUD_SOURCE >= 2
| Show %d0 as "USBAUD xxxxxxxx" via the firmware's dismissible popup. In the
| PAYLOAD (not the image reporter zone), so adding a probe never costs a
| reflash -- only the card file changes.
.set POPUP_FN, 0x4005a2b8
audio_show_hex:
    lea     %sp@(-16),%sp
    moveml  %d1-%d3/%a0,%sp@
    movel   %d0,%d1
    lea     aud_hexmsg+15,%a0
    moveq   #7,%d3
.Lhex_digit:
    movel   %d1,%d2
    andil   #15,%d2
    addil   #0x30,%d2
    cmpil   #0x39,%d2
    bles    .Lhex_store
    addil   #7,%d2
.Lhex_store:
    moveb   %d2,%a0@-
    lsrl    #4,%d1
    subql   #1,%d3
    bpls    .Lhex_digit
    pea     0x30
    pea     aud_hexmsg
    movel   #POPUP_FN,%a0
    jsr     %a0@
    lea     %sp@(8),%sp
    moveml  %sp@,%d1-%d3/%a0
    lea     %sp@(16),%sp
    rts
aud_hexmsg:
    .asciz  "USBAUD 00000000"
    .balign 2
    .endif

| ---- the per-block producer (installed at 0x4000d9a0, inside frame_isr) ----
| frame_isr runs once per 16-frame block on real hardware. This is the whole
| reason the feature can work on a unit: the block clock, the audio and the
| trigger to send are all firmware events, with nothing supplied by the
| emulator.
|
| ☠ The hook site is the LAST instruction before frame_isr's
| `moveml %sp@,%d0-%fp` epilogue, so every register is about to be reloaded
| from the stack — this shim may clobber d0-a6 freely. It must not touch %sp.
|
| Displaced: clrl 0x46104d4e (6 bytes), rejoin 0x4000d9a6.

| d -> saturated to 24 bits (-2^23 .. 2^23-1). Inline, used only for the
| stereo sum (two per frame). The bounds live in %a5 (0x7fffff) and %a6
| (-0x800000), loaded once per block.
.macro SAT24 d
    cmpl    %a5,\d
    jble    .Lsat_lo\@              | jbcc: gas picks the shortest branch
    movel   %a5,\d
    jbra    .Lsat_ok\@
.Lsat_lo\@:
    cmpl    %a6,\d
    jbge    .Lsat_ok\@
    movel   %a6,\d
.Lsat_ok\@:
.endm

    .global audio_frame_shim
audio_frame_shim:
    | ☠ The producer used to idle until the host opened the stream, so the ring
    | was empty at alt 1 and the first ~127 packets could not be filled --
    | measured on hardware as exactly 127 underruns, all at startup, and heard
    | as a burst of clicks in the first 1.5 s. Keeping it running costs one
    | block of copying per interrupt whether or not anyone is listening, and
    | buys a stream that starts instantly with a full buffer behind it.
    | aud_running gates the SENDING, just not the producing.
audio_frame_shim_body:
    .if AUD_SOURCE != 6
    | ☠ The stereo sum is only ever SENT at full speed. At high speed (PORTSC1
    | bits 27:26 = 2) its store is skipped. Decided per block from the PORT,
    | not from aud_hs, so a re-enumeration at full speed refills the sum ring
    | long before the host can select alt 1 (enumeration alone takes
    | >100 ms; the ring holds 23 ms). A telemetry build keeps it: the
    | telemetry rides on the sum's left channel.
    moveq   #0,%d1
    movel   PORTSC1,%d0
    andil   #0x0c000000,%d0
    cmpil   #0x08000000,%d0
    seq     %d1                     | d1 = 0xff at high speed
    moveal  %d1,%a1                 | a1 != 0: skip the sum this block
    .else
    suba    %a1,%a1                 | never skip
    .endif
    movel   RB_PREV,%d0
    | ☠ Telemetry: does the ping-pong bank actually alternate? Hardware shows
    | zero overruns and zero steady-state underruns, so mid-stream clicks
    | cannot be dropped or duplicated PACKETS -- which leaves the producer
    | reading the same bank twice (a duplicated 16-frame block) or skipping
    | one. Counted here so it is measurable instead of inferred.
    movel   %d0,%d2
    cmpl    usbaudio_lastbank,%d2
    bnes    .Lbank_ok
    addql   #1,usbaudio_bankdup
.Lbank_ok:
    movel   %d2,usbaudio_lastbank
    lsll    #8,%d0
    lsll    #2,%d0                  | prev * 1024 (imm shift is 1-8)
    addil   #RB_BASE,%d0
    moveal  %d0,%a2                 | a2 = this bank's track 0, frame 0
    movel   aud_produced,%d4
    movel   %d4,%d5
    andil   #AUD_FRAMES-1,%d5
    movel   %d5,%d0
    MUL_SLOT %d0, %d2               | d2 is dead here (lastbank is stored)
    lea     aud_ring,%a3
    addal   %d0,%a3                 | a3 = 16-channel slot cursor (a block never
                                    | wraps: 16 divides the ring size)
    lsll    #3,%d5
    lea     aud_sum,%a4
    addal   %d5,%a4                 | a4 = stereo-sum cursor
    moveq   #SUM_SHIFT,%d1          | asr.l immediate is 1-8 only: shift via d1
    moveal  #0x7fffff,%a5           | SAT24 bounds
    moveal  #-0x800000,%a6
    moveq   #15,%d6                 | 16 frames
1:
    .if SRC_IS_TRACKS
    | ---- the eight tracks, one stereo pair each, plus their sum -----------
    | Per frame: track t's L,R (32-bit, post-FX, pre-fader) with the low byte
    | cleared -- 24 bits, left-justified in the subslot, no saturation needed
    | -- then BYTEREV (ISA_C, and QEMU's cfv4e has it) to little-endian, one
    | longword store each, at slot + t*8. The same words >> 8 accumulate into
    | the stereo sum in 24-bit units (d5 = L, d3 = R; eight tracks fit in 27
    | bits), which is what the full-speed stream carries.
    moveal  %a2,%a0                 | track 0, this frame
    moveq   #0,%d5                  | L sum
    moveq   #0,%d3                  | R sum
    moveq   #RB_TRACKS-1,%d7
2:  movel   %a0@,%d2                | track L
    movel   %d2,%d0
    asrl    %d1,%d0
    addl    %d0,%d5
    clrb    %d2                     | the top 24 bits
    byterev %d2
    movel   %d2,%a3@+
    movel   %a0@(4),%d2             | track R
    movel   %d2,%d0
    asrl    %d1,%d0
    addl    %d0,%d3
    clrb    %d2
    byterev %d2
    movel   %d2,%a3@+
    lea     %a0@(128),%a0           | next track, same frame
    subql   #1,%d7
    bpl     2b
    | ---- MAIN and CUE, channels 17-20: the same word format, top 24 bits --
    | Frame f's pair sits at MC_BASE + f*8 (+MC_CUE_OFF for CUE); f = 15 - d6.
    | a0 and d7 are free until the next frame reloads them.
    moveq   #15,%d7
    subl    %d6,%d7
    lsll    #3,%d7                  | f * 8
    lea     MC_BASE,%a0
    addal   %d7,%a0
    movel   %a0@(MC_MAIN_OFF),%d2   | MAIN L
    clrb    %d2
    byterev %d2
    movel   %d2,%a3@+
    movel   %a0@(MC_MAIN_OFF+4),%d2 | MAIN R
    clrb    %d2
    byterev %d2
    movel   %d2,%a3@+
    movel   %a0@(MC_CUE_OFF),%d2    | CUE L
    clrb    %d2
    byterev %d2
    movel   %d2,%a3@+
    movel   %a0@(MC_CUE_OFF+4),%d2  | CUE R
    clrb    %d2
    byterev %d2
    movel   %d2,%a3@+
    movel   %d5,%d2                 | the stereo sum, L
    .else
    | ---- diagnostic source: synthetic 441 Hz triangle, +-8000/32768 -------
    | Ignores readback_buf entirely, on ALL sixteen channels and the sum.
    | Separates "can the device produce samples over USB at all" from "is the
    | tap point carrying audio". 100 frames per cycle at 44100 = 441 Hz, which
    | is also the emulator gate's tone.
    | ☠ No mulsl: 320 = 256 + 64 via shifts, because ColdFire immediate
    | multiply forms are not dependable here.
    movel   aud_phase,%d2
    cmpil   #50,%d2
    bges    .Lsyn_down
    movel   %d2,%d7
    lsll    #8,%d7                  | phase * 256
    lsll    #6,%d2                  | phase * 64
    addl    %d7,%d2                 | phase * 320
    subil   #8000,%d2               | rising: -8000 -> +8000
    bras    .Lsyn_have
.Lsyn_down:
    subil   #50,%d2
    movel   %d2,%d7
    lsll    #8,%d7
    lsll    #6,%d2
    addl    %d7,%d2                 | (phase-50) * 320
    movel   #8000,%d0
    subl    %d2,%d0                 | falling: +8000 -> -8000
    movel   %d0,%d2
.Lsyn_have:
    movel   aud_phase,%d0
    addql   #1,%d0
    cmpil   #100,%d0
    blts    .Lsyn_wrap
    moveq   #0,%d0
.Lsyn_wrap:
    movel   %d0,aud_phase
    lsll    #8,%d2                  | 16-bit units -> 24-bit units
    movel   %d2,%d3                 | R sum = the tone too
    movel   %d2,%d0
    lsll    #8,%d0                  | left-justified in the subslot
    byterev %d0
    moveq   #19,%d7                 | all 20 channels of the slot
.Lsyn_fill:
    movel   %d0,%a3@+
    subql   #1,%d7
    bpls    .Lsyn_fill
    .endif
    movel   %a1,%d0
    bne     .Lsum_skip              | high speed: the sum ring is not sent
    | ---- the stereo sum: saturate, left-justify, store little-endian --------
    SAT24   %d2
    | ☠ producer-side discontinuity detector (telemetry only; the compare is a
    | few cycles and the counter is never read on a normal build). The
    | threshold is his 800 in 16-bit units.
    movel   usbaudio_lastsamp,%d0
    subl    %d2,%d0
    bpls    .Lsj_abs
    negl    %d0
.Lsj_abs:
    cmpil   #(800<<8),%d0
    bcss    .Lsj_done
    addql   #1,usbaudio_srcjump
.Lsj_done:
    movel   %d2,usbaudio_lastsamp
    .if AUD_SOURCE == 6
    | ☠ Telemetry rides on the LEFT channel of the sum AND of track 1 (slot
    | channel 0), substituted AFTER the detector above has compared real
    | samples. Every other channel stays real audio, so the same capture is
    | both measurable and listenable.
    movel   %d6,%d0
    movel   #15,%d1
    subl    %d0,%d1                 | d1 = frame index within the block
    bsr     audio_telem_value       | d1 -> d2 = the field for this frame
    moveq   #SUM_SHIFT,%d1          | restore the shift
    movel   %d2,%d0
    lsll    #8,%d0
    lsll    #8,%d0                  | the 16-bit field, left-justified
    byterev %d0
    movel   %d0,%a3@(-SLOT_BYTES)
    lsll    #8,%d2                  | and in 24-bit units for the sum
    .endif
    movel   %d2,%d0
    lsll    #8,%d0
    byterev %d0
    movel   %d0,%a4@+               | sum L
    movel   %d3,%d0
    SAT24   %d0
    lsll    #8,%d0
    byterev %d0
    movel   %d0,%a4@+               | sum R
.Lsum_skip:
    lea     %a2@(8),%a2             | next frame
    subql   #1,%d6
    bpl     1b                      | not bpls: the loop body is long
    addql   #8,%d4
    addql   #8,%d4                  | 16 frames produced
    movel   %d4,aud_produced
    | ---- EP3, owned by this context alone ---------------------------------
    | usbaudio_alt is what the host asked for (SET_INTERFACE); aud_running is
    | what EP3 currently is. Bring it up or down when they differ, and when
    | it is up the block clock IS the send clock: top the queue up now.
    mvzb    usbaudio_alt,%d0
    mvzb    aud_running,%d1
    cmpl    %d0,%d1
    beqs    .Lep3_same
    tstl    %d0
    beqs    .Lep3_down
    bsr     audio_ep3_up
    bras    .Lep3_kick
.Lep3_down:
    bsr     audio_ep3_down
    bras    9f
.Lep3_same:
    tstl    %d1
    beqs    9f                      | nobody listening: produce, but do not send
.Lep3_kick:
    bsr     usbaudio_kick
9:  clrl    0x46104d4e              | displaced
    jmp     0x4000d9a6

| ---- UAC2 class-request shim (installed at 0x4001de64) ----------------------
| Displaced: movel 0xfc0b01c0,%d0 — the first instruction of the stock
| "unknown request: STALL EP0" tail, which every request the dispatcher does
| not recognise falls into. A UAC2 host asks the CLOCK SOURCE for its sample
| rate before it will publish a device (RANGE + CUR of CS_SAM_FREQ_CONTROL,
| CUR of CS_CLOCK_VALID_CONTROL, all class GET to the AudioControl interface
| with the entity id in wIndex's high byte), and a STALL there means no
| audio device. Everything else falls through to the stock STALL, which is
| the legal answer for a control we do not implement.
|
| Reply the way the stock string-descriptor path does: push the buffer and
| min(wLength, len) and jump to the shared usb_ep0_send tail. d2 still holds
| wLength here (nothing between the dispatcher and the stall touches it). The
| reply buffers are CONSTANTS in this blob: the EP0 send DMAs them straight
| out of memory, and the loader's cache push after relocation is the last
| time they may be written.
    .global audio_ctrl_shim
audio_ctrl_shim:
    mvzb    SETUP_BMREQ,%d0
    | octabam: a vendor GET (bmRequestType 0xc0, bRequest 0x55) reads the
    | twelve counters below back over EP0 as 48 big-endian bytes, so a
    | host -- the port's bench, or tools/hw/usb_counters.py on a unit --
    | can watch underruns, overruns and the bank-duplicate count during a
    | stream. Any driver a host attached to the interfaces is bypassed: a
    | device-recipient control request needs no interface claim.
    cmpil   #0xc0,%d0
    bnes    .Lctrl_class
    mvzb    SETUP_BREQ,%d0
    cmpil   #0x55,%d0
    bne     .Lctrl_stock
    pea     usbaudio_consumed
    moveq   #48,%d0
    bra     .Lctrl_send
.Lctrl_class:
    cmpil   #0xa1,%d0               | class GET, interface recipient
    bne     .Lctrl_stock
    mvzb    SETUP_IFACE,%d0
    cmpil   #UAC2_AC_IFACE,%d0      | the audio function's AudioControl
    bne     .Lctrl_stock
    mvzb    SETUP_WIDXH,%d0
    cmpil   #UAC2_CLOCK_ID,%d0      | the clock source entity
    bne     .Lctrl_stock
    mvzb    SETUP_WVALH,%d0         | control selector
    mvzb    SETUP_BREQ,%d1          | 1 = CUR, 2 = RANGE
    cmpil   #1,%d0                  | CS_SAM_FREQ_CONTROL
    beqs    .Lctrl_freq
    cmpil   #2,%d0                  | CS_CLOCK_VALID_CONTROL
    bne     .Lctrl_stock
    cmpil   #1,%d1
    bne     .Lctrl_stock            | only CUR exists for validity
    pea     uac2_clock_valid
    moveq   #1,%d0
    bras    .Lctrl_send
.Lctrl_freq:
    cmpil   #1,%d1
    bnes    .Lctrl_freq_range
    pea     uac2_freq_cur
    moveq   #4,%d0
    bras    .Lctrl_send
.Lctrl_freq_range:
    cmpil   #2,%d1
    bne     .Lctrl_stock
    pea     uac2_freq_range
    moveq   #14,%d0
.Lctrl_send:
    cmpl    %d2,%d0                 | min(wLength, len)
    blss    1f
    movel   %d2,%d0
1:  movel   %d0,%sp@-
    jmp     EP0_SEND_TAIL
.Lctrl_stock:
    movel   0xfc0b01c0,%d0          | displaced
    jmp     CTRL_STOCK

    .data
| UAC2 clock-source replies, little-endian on the wire (his; constant, the
| EP0 send DMAs them straight out of this unit).
    .balign 4
uac2_freq_cur:   .byte 0x44,0xac,0x00,0x00          | 44100
uac2_freq_range: .byte 0x01,0x00                    | wNumSubRanges = 1
                 .byte 0x44,0xac,0x00,0x00          | dMIN 44100
                 .byte 0x44,0xac,0x00,0x00          | dMAX 44100
                 .byte 0x00,0x00,0x00,0x00          | dRES 0
uac2_clock_valid: .byte 0x01

| ---- payload state ----------------------------------------------------------
    .balign 4
    .global usbaudio_consumed, usbaudio_acc, usbaudio_overruns
    .global usbaudio_underruns, usbaudio_lastn, usbaudio_lastfill
    .global usbaudio_lastbank, usbaudio_bankdup, usbaudio_srcjump
    .global usbaudio_reprimes
| The twelve longs from usbaudio_consumed to aud_produced are what the
| vendor request 0xc0/0x55 returns, in this order.
usbaudio_consumed: .long 0          | frames pulled from the ring
usbaudio_acc:      .long 0          | frames-per-packet accumulator (x1000)
usbaudio_overruns: .long 0
usbaudio_underruns: .long 0    | packets we could not fill
usbaudio_lastn:    .long 0    | frames in the most recent packet
usbaudio_lastfill: .long 0    | ring fill at the most recent packet
usbaudio_lastbank: .long -1   | previous ping-pong bank
usbaudio_bankdup:  .long 0    | blocks where the bank did NOT alternate
usbaudio_lastsamp: .long 0    | previous summed L sample
usbaudio_srcjump:  .long 0    | discontinuities present at production
usbaudio_reprimes: .long 0    | idle endpoint found holding a queued dTD
aud_produced:      .long 0          | producer frame count (relocates with us)
aud_phase:         .long 0          | synthetic-source phase, 0..99
qh_ep3:            .long 0          | EP3 IN dQH, read from ENDPTLISTADDR
aud_step:          .long STEP_HS    | frames per packet x1000, set by the speed
aud_ring:          .space AUD_FRAMES*SLOT_BYTES  | 1024 x 20 ch, 24 in 4 B LE
aud_sum:           .space AUD_FRAMES*SUM_BYTES   | 1024 x stereo sum, 24 in 4 B LE
usbaudio_alt:      .byte 0          | alt setting the host asked for
aud_running:       .byte 0          | EP3 is up (frame-ISR owned)
aud_hs:            .byte 0          | 1 = high speed (20 ch), 0 = full (sum)
aud_tail:          .byte 0          | next dTD slot to fill (0..NSLOT-1)

| ☠ Everything the USB controller reads by DMA is read and written by the
| CPU ONLY through the uncached alias (address + UNCACHED). The unit runs
| from SDRAM that ACR0 maps cacheable copyback, and the controller is a bus
| master that does not snoop the CPU's data cache -- so a dTD written through
| its cached address can still be dirty in cache when the controller fetches
| it, and the controller then reads whatever RAM held before. That presented
| on hardware as ENDPTPRIME clearing (the prime was consumed) while ENDPTSTAT
| never armed (the descriptor it found was not ACTIVE); per-line cpushl did
| NOT fix it, in either form; uncached structures did, first try (his
| window at 0x4ec94a00 is itself an alias address). The loader writes this
| unit through the same alias and no code names these two arrays by their
| cached addresses, so nothing allocates a cache line for them (inferred
| from the access paths, not measured). dTDs are
| 32-byte aligned (the dQH and dTD next pointers keep bits 31:5 only).
    .balign 32
aud_dtds:          .space NSLOT*32               | EP3 IN dTDs, one per queue slot
aud_bufs:          .space NSLOT*PKT_MAX_HS       | their packets (<= 960 B each)

    .balign 4
