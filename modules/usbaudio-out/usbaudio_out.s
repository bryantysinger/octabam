| usbaudio_out.s -- USB AUDIO OUT: four channels from the host into inputs A-D.
|
| The host streams AudioStreaming interface 5 alt 1 on EP3 OUT: isochronous,
| asynchronous with IMPLICIT feedback (EP3 IN is the feedback source, so the
| host sizes each OUT packet from the IN stream's), 4 channels x 24-bit in
| 4-byte little-endian subslots, 11/12 frames per 250 us packet (<= 192 B).
|
|   USB side (this unit, all in the frame transfer machine's state 7):
|     EP3 OUT up/down follows the host's SET_INTERFACE(5); four dTDs stay
|     queued; each retired dTD's frames go into a 1,024-frame ring and the
|     dTD is queued again at the tail (the Chipidea add-dTD procedure, as
|     usbaudio.s does for EP3 IN).
|   DSP side: once per 16-sample frame, 16 ring frames become 128 host-port
|     halfwords in DSP slot order (slot 0/1 = inputs C/D, 2/3 = A/B, the
|     firmware's GAIN assignment, confirmed on hardware 26 Sep 2026) and go
|     to core 0 at $6320, i.e. the idle bank + $320 (plan doc 4a/5). The
|     DSP inject (manifest.py) copies them over the RX block the next frame.
|   Stream flag: bit 8 of the first sample's low halfword. Set while the
|     stream is open; clear otherwise, and the DSP then leaves the RX block
|     alone -- the jacks (Bryan T, 26 Sep 2026).
|
| Hooks (manifest.py):
|   0x4001dd0a  SET_INTERFACE: usbaudio's shim sends every interface but 4
|               here; interface 5 records the alt and ACKs, the rest goes on
|               to the stock (mass-storage) handler.
|   0x40004bc0  frame transfer state 7 (8 bytes): first visit does the work
|               and starts one more transfer; its completion is the second
|               visit, which runs stock state 7 (the frame IRQ unmask).
|
| Memory: DMA-visible structures (dTDs, packet buffers, the host-port
| buffer) are touched only through the uncached alias (+0x08000000), the
| rule usbaudio.s arrived at on hardware. The ring and the state are CPU-only.
|
| Latency: the ring runs at OUT_TARGET frames of cushion. With implicit
| feedback the host's OUT rate follows EP3 IN's packet sizes, and those
| follow usbaudio's rate servo, which leaves the IN ring free to wander by
| its deadband (AUD_BAND, +-128 frames) before it steers. The OUT ring
| mirrors that wander, and from wherever the IN fill sat when the OUT stream
| started it can swing by the band's full width, 256 frames. OUT_TARGET =
| 384 (8.7 ms) covers that plus a block, a packet and margin. Under the port
| (26 Sep 2026, host IN and OUT in the same poll) 320 ran 24,000 polls with
| 0 underruns and one 8,000-poll run with 1, so 384 is the conservative
| pick until the unit's own min/max fill (vendor request 0x56 below) says
| how far it really swings. A tighter IN deadband is what would let it
| come down.
| SPDX-License-Identifier: MIT

.set UNCACHED,       0x08000000

| ---- firmware sites (1.40C) ----
.set SETUP_ALT,      0x46c8ce0a     | SETUP wValue low = alt setting
.set SETUP_IFACE,    0x46c8ce0c     | SETUP wIndex low = interface number
.set SETUP_BMREQ,    0x46c8ce08     | SETUP bmRequestType
.set SETUP_BREQ,     0x46c8ce09     | SETUP bRequest
.set SETUP_WLENL,    0x46c8ce0e     | SETUP wLength low
.set SETUP_WLENH,    0x46c8ce0f     | SETUP wLength high
.set EP0_SEND_TAIL,  0x4001de5c     | jsr usb_ep0_send(len, buf); addq; done
.set EP0CTRL,        0xfc0b01c0     | ENDPTCTRL0
.set VENDOR_REQ,     0x56           | usbaudio answers 0x55 with its own
.set NCOUNT,         13             | longs in out_counters
.set EP0_STATUS_IN,  0x4001d524     | zero-length EP0 IN status (ACK)
.set SETIFACE_DONE,  0x4001de74     | control-request-done
.set SETIFACE_REJOIN,0x4001dd10     | stock SET_INTERFACE after the displaced oril
.set STATE7_DONE,    0x40004bc8     | the transfer IRQ's movem restore + rte
.set FRAME_UNMASK,   0xfc04801d     | stock state 7's write (INTC0 CIMR <- 1)

| ---- USB controller ----
.set EPLISTADDR, 0xfc0b0158
.set ENDPTSTAT,  0xfc0b01b8
.set EPPRIME,    0xfc0b01b0
.set EPFLUSH,    0xfc0b01b4
.set EPCOMPLETE, 0xfc0b01bc
.set ENDPTCTRL3, 0xfc0b01cc
.set USBCMD,     0xfc0b0140
.set ATDTW,      0x00004000
.set PORTSC1,    0xfc0b0184
.set QH_LIST,    0x4ec94800         | the firmware's dQH list (fallback)
.set QH_EP3OUT_OFF, 6*64            | EP3 OUT is list entry 3*2
.set EP3OUT_BIT, 0x00000008         | ENDPTPRIME/STAT/COMPLETE/FLUSH bit
.set CTRL3_RX,   0x00000084         | ENDPTCTRL3 RX half: RXE + isochronous

| ---- the eDMA / host port (as states 4/5 program them) ----
.set EDMA_SADDR, 0xfc045000
.set EDMA_NBYTES,0xfc045008
.set EDMA_CITER, 0xfc045014
.set EDMA_BITER, 0xfc04501c
.set EDMA_START, 0xfc04401e
.set CORE_SEL,   0xfc0a400c
.set HOST_ICR,   0x20000000
.set HOST_CVR,   0x20000004
.set HOST_DATA,  0x2000001c
.set DSP_DEST,   0x6320             | idle bank + $320 after the DSP's mask

| ---- geometry ----
.set OUT_IFACE,  5
.set NSLOTO,     4                  | dTDs kept queued (1 ms of packets)
.set OPKT,       192                | 12 frames x 16 B: the largest packet
.set FRAME_B,    16                 | 4 ch x 4 B
.set OUT_FRAMES, 1024               | ring, frames (power of two)
.set OUT_TARGET, 384                | cushion before consuming, 8.7 ms (see Latency)
.set BLOCK,      16                 | DSP frame
.set TX_BYTES,   256                | 128 halfwords to the DSP
.set FLAG,       0x0100             | stream flag, first low halfword

    .text
| ---- SET_INTERFACE (0x4001dd0a) ---------------------------------------------
| Displaced: oril #0x00400040,%d0 (d0 = ENDPTCTRL1, loaded by the stock
| movel or by usbaudio's shim). d1 is free until 0x4001dd2e reloads it.
    .global out_setiface_shim
out_setiface_shim:
    mvzb    SETUP_IFACE,%d1
    cmpil   #OUT_IFACE,%d1
    beqs    1f
    oril    #0x00400040,%d0         | displaced
    jmp     SETIFACE_REJOIN
1:  mvzb    SETUP_ALT,%d1
    tstl    %d1
    beqs    2f
    moveq   #1,%d1                  | any non-zero alt is the streaming one
2:  moveb   %d1,out_alt             | the request; state 7 brings EP3 OUT up/down
    jsr     EP0_STATUS_IN
    jmp     SETIFACE_DONE

| ---- vendor GET 0x56 (installed at 0x4001de6e) ------------------------------
| Displaced: movel %d0,0xfc0b01c0 -- the stall's store (ENDPTCTRL0 with the
| stall bits already set in d0). Two paths reach it: the unknown-request tail
| (0x4001de6a's bset, which usbaudio's class shim also falls back into) and a
| standard-request stall (braw 0x4001de6e at 0x4001dd00). The bset site
| itself is 4 bytes and a 6-byte jmp there would cover that branch target.
| bmRequestType 0xc0 / bRequest 0x56 answers out_counters (NCOUNT big-endian
| longs) instead of stalling; everything else stalls as stock. wLength comes
| from the SETUP packet, not d2: d2 is wLength on usbaudio's path but not
| provably on the 0x4001dd00 one. d1 is dead here (both paths end in the
| handler's epilogue at 0x4001de74). The buffer is cached DRAM, the same as
| usbaudio's 0x55 counters, which read correctly on the unit (25 Sep 2026).
    .global out_ctrl_shim
out_ctrl_shim:
    mvzb    SETUP_BMREQ,%d1
    cmpil   #0xc0,%d1
    bnes    9f
    mvzb    SETUP_BREQ,%d1
    cmpil   #VENDOR_REQ,%d1
    bnes    9f
    pea     out_counters
    mvzb    SETUP_WLENH,%d1
    lsll    #8,%d1
    mvzb    SETUP_WLENL,%d0
    orl     %d1,%d0                 | wLength
    moveq   #NCOUNT*4,%d1
    cmpl    %d0,%d1
    bhis    1f                      | len > wLength: send wLength
    movel   %d1,%d0
1:  movel   %d0,%sp@-
    jmp     EP0_SEND_TAIL
9:  movel   %d0,EP0CTRL             | displaced: the stall
    jmp     SETIFACE_DONE

| ---- state 7 (0x40004bc0) -----------------------------------------------------
| The transfer IRQ saved d0-d1/a0-a1; everything else is saved here.
    .global out_state7_shim
out_state7_shim:
    tstb    out_busy
    bnes    .Ls7_second
    moveq   #1,%d0
    moveb   %d0,out_busy
    lea     %sp@(-40),%sp
    moveml  %d2-%d7/%a2-%a5,%sp@
    bsr     out_frame
    moveml  %sp@,%d2-%d7/%a2-%a5
    lea     %sp@(40),%sp
    bsr     out_dma_start
    jmp     STATE7_DONE
.Ls7_second:
    addql   #1,out_seconds
    clrb    out_busy
    moveq   #1,%d1                  | stock state 7, displaced
    moveb   %d1,FRAME_UNMASK
    jmp     STATE7_DONE

| One more host-port transfer: 128 halfwords from out_tx to core 0 at $6320,
| eDMA ch 0 exactly as states 4/5 set it up.
out_dma_start:
    clrb    %d0
    moveb   %d0,CORE_SEL            | core 0
    moveq   #64,%d1
    movel   %d1,EDMA_NBYTES
    movel   #(out_tx+UNCACHED),%d1
    movel   %d1,EDMA_SADDR
    movew   #0x81,%d0
    movew   %d0,HOST_ICR
    movew   #DSP_DEST,%d1
    movew   %d1,HOST_DATA
    movew   #127,%d0
    movew   %d0,HOST_DATA
    movew   #0x88,%d1
    movew   %d1,HOST_CVR
    movew   #0x8004,%d0
    movew   %d0,EDMA_CITER
    movew   %d0,EDMA_BITER
    clrb    %d1
    moveb   %d1,EDMA_START
    rts

| ---- the per-frame work ----------------------------------------------------
| May clobber d0-d7/a0-a5.
out_frame:
    addql   #1,out_frames           | state-7 visits = DSP frames
    mvzb    out_alt,%d0
    mvzb    out_running,%d1
    cmpl    %d0,%d1
    beqs    1f
    tstl    %d0
    beqs    2f
    bsr     out_up
    bras    1f
2:  bsr     out_down
1:  tstb    out_running
    beqs    .Lf_idle
    movel   #EP3OUT_BIT,%d0
    movel   %d0,EPCOMPLETE          | W1C: no IOC, so this bit never interrupts
    bsr     out_retire
    bsr     out_selfheal
    bra     out_build
.Lf_idle:
    moveal  #(out_tx+UNCACHED),%a1
    clrl    %a1@                    | first sample's two halfwords: flag clear
    rts

| Bring EP3 OUT up. High speed only (the full-speed OUT alt is declared but
| not served: the IN side sends the stereo sum there). Stays down otherwise,
| and is retried every frame while the host asks for alt 1.
out_up:
    movel   PORTSC1,%d0
    andil   #0x0c000000,%d0
    cmpil   #0x08000000,%d0
    bne     9f
    bsr     out_flush
    bsr     out_qh_resolve          | a0 = EP3 OUT dQH
    moveq   #15,%d1
1:  clrl    %a0@+                   | the whole dQH: its token and pointers
    subql   #1,%d1                  | are power-on garbage (usbaudio.s)
    bpls    1b
    moveal  qh_out,%a0
    movel   #(0x60000000+(OPKT<<16)),%d0   | Mult 1, ZLT off, maxpkt 192
    movel   %d0,%a0@
    moveq   #1,%d0
    movel   %d0,%a0@(8)             | next dTD: terminate
    movel   ENDPTCTRL3,%d0          | the RX half only: EP3 IN owns TX
    andil   #0xffff0000,%d0
    oril    #CTRL3_RX,%d0
    movel   %d0,ENDPTCTRL3
    clrl    out_produced
    clrl    out_consumed
    moveq   #-1,%d0
    movel   %d0,out_minfill
    clrl    out_maxfill
    moveq   #1,%d0
    moveb   %d0,out_prefill
    clrb    out_ri
    bsr     out_arm_all
    moveq   #1,%d0
    moveb   %d0,out_running
9:  rts

out_down:
    bsr     out_flush
    movel   ENDPTCTRL3,%d0
    andil   #0xffff0000,%d0         | RX half off, TX half as it was
    movel   %d0,ENDPTCTRL3
    moveal  #(out_dtds+UNCACHED),%a1
    moveq   #NSLOTO*8-1,%d1
1:  clrl    %a1@+
    subql   #1,%d1
    bpls    1b
    clrb    out_running
    rts

| Flush EP3 OUT, bounded, repeating while it still shows primed.
out_flush:
    moveq   #16,%d1
1:  movel   #EP3OUT_BIT,%d0
    movel   %d0,EPFLUSH
2:  movel   EPFLUSH,%d0
    andil   #EP3OUT_BIT,%d0
    bnes    2b
    movel   ENDPTSTAT,%d0
    andil   #EP3OUT_BIT,%d0
    beqs    3f
    subql   #1,%d1
    bnes    1b
3:  rts

| EP3 OUT's queue head from ENDPTLISTADDR (a value outside SDRAM is not a
| list: the firmware's constant then). -> a0, cached in qh_out.
out_qh_resolve:
    movel   EPLISTADDR,%d0
    andil   #0xfffff800,%d0
    cmpil   #0x40000000,%d0
    blts    1f
    cmpil   #0x50000000,%d0
    blts    2f
1:  movel   #QH_LIST,%d0
2:  addil   #QH_EP3OUT_OFF,%d0
    movel   %d0,qh_out
    moveal  %d0,%a0
    rts

| d0 = slot (mod NSLOTO) -> a0 = its dTD, a3 = its buffer (both uncached).
| Clobbers d0/d1.
out_slot:
    andil   #NSLOTO-1,%d0
    movel   %d0,%d1
    lsll    #5,%d0
    moveal  #(out_dtds+UNCACHED),%a0
    addal   %d0,%a0
    moveal  #(out_bufs+UNCACHED),%a3
    lsll    #6,%d1                  | slot * 64
    addal   %d1,%a3
    addal   %d1,%a3
    addal   %d1,%a3                 | + slot * 192 (OPKT)
    rts

| Write slot d2's dTD for one packet: buffer pages, next = terminate, then
| the ACTIVE token LAST (uncached stores reach memory in program order).
| -> a0 = the dTD. Clobbers d0/d1/a3.
out_dtd_fill:
    movel   %d2,%d0
    bsr     out_slot
    moveq   #1,%d0
    movel   %d0,%a0@                | next = terminate
    movel   %a3,%a0@(8)             | page 0
    movel   %a3,%d0
    andil   #0xfffff000,%d0
    addil   #0x1000,%d0
    movel   %d0,%a0@(12)            | page 1: a buffer may straddle 4 KB
    movel   #((OPKT<<16)+0x80),%d0  | total bytes, ACTIVE, no IOC
    movel   %d0,%a0@(4)
    rts

| Queue all NSLOTO dTDs as one chain and prime.
out_arm_all:
    moveq   #NSLOTO-1,%d2
1:  bsr     out_dtd_fill            | back to front: each links the next
    movel   %d2,%d0
    addql   #1,%d0
    cmpil   #NSLOTO,%d0
    beqs    2f
    moveal  %a0,%a4
    bsr     out_slot                | a0 = the next dTD
    movel   %a0,%a4@                | this.next = next
    moveal  %a4,%a0
2:  subql   #1,%d2
    bpls    1b
    moveal  qh_out,%a1              | a0 = slot 0, the head
    movel   %a0,%a1@(8)
    clrl    %a1@(12)
    movel   #EP3OUT_BIT,%d0
    movel   %d0,EPPRIME
    rts

| Retire completed dTDs in queue order into the ring, and queue each again.
out_retire:
    moveq   #NSLOTO,%d7             | at most one lap
.Lr_next:
    mvzb    out_ri,%d2
    movel   %d2,%d0
    bsr     out_slot
    movel   %a0@(4),%d3             | token
    btst    #7,%d3
    bne     .Lr_done                | still ACTIVE: nothing more has landed
    movel   %d3,%d0
    andil   #0x68,%d0               | halted, buffer error, transaction error
    beqs    1f
    addql   #1,out_bad
1:  movel   %d3,%d0
    swap    %d0
    andil   #0x7fff,%d0             | bytes left
    movel   #OPKT,%d4
    subl    %d0,%d4                 | d4 = bytes received
    bcs     .Lr_requeue             | nonsense: drop it
    movel   %d4,%d0
    andil   #FRAME_B-1,%d0
    beqs    2f
    addql   #1,out_bad              | not whole frames
2:  lsrl    #4,%d4                  | frames
    movel   %d4,out_lastn
    addql   #1,out_pkts
    tstl    %d4
    beqs    .Lr_requeue
    | copy d4 frames from a3 into the ring at out_produced
    lea     out_ring,%a2
    movel   out_produced,%d5
3:  movel   %d5,%d0
    andil   #OUT_FRAMES-1,%d0
    lsll    #4,%d0
    lea     %a2@(0,%d0:l),%a1
    movel   %a3@+,%a1@+
    movel   %a3@+,%a1@+
    movel   %a3@+,%a1@+
    movel   %a3@+,%a1@+
    addql   #1,%d5
    subql   #1,%d4
    bnes    3b
    movel   %d5,out_produced
    subl    out_consumed,%d5        | fill
    cmpil   #OUT_FRAMES,%d5
    blss    .Lr_requeue
    addql   #1,out_overruns         | host ahead by a whole ring: resync
    movel   out_produced,%d0
    subil   #OUT_TARGET,%d0
    movel   %d0,out_consumed
.Lr_requeue:
    bsr     out_dtd_fill            | slot d2 again, ACTIVE
    bsr     out_enqueue
    movel   %d2,%d0
    addql   #1,%d0
    andil   #NSLOTO-1,%d0
    moveb   %d0,out_ri
    subql   #1,%d7
    bne     .Lr_next
.Lr_done:
    rts

| Append the just-filled dTD (a0, slot d2) after slot d2-1, the Chipidea
| add-dTD procedure (usbaudio.s audio_pkt_build has the commentary).
| Clobbers d0/d1/d3/a1/a3/a4/a5.
out_enqueue:
    moveal  %a0,%a5                 | this
    movel   %d2,%d0
    subql   #1,%d0
    bsr     out_slot                | a0 = previous
    moveal  %a0,%a1
    moveal  %a5,%a0
    movel   %a1@(4),%d0
    btst    #7,%d0
    beqs    .Le_prime               | previous retired: list empty
    movel   %a0,%a1@                | previous.next = this
    movel   EPPRIME,%d0
    andil   #EP3OUT_BIT,%d0
    bnes    .Le_done                | a prime is pending: it reads the list
    moveq   #16,%d3
.Le_trip:
    movel   USBCMD,%d0
    oril    #ATDTW,%d0
    movel   %d0,USBCMD
    movel   ENDPTSTAT,%d1
    andil   #EP3OUT_BIT,%d1
    movel   USBCMD,%d0
    andil   #ATDTW,%d0
    bnes    .Le_sampled
    subql   #1,%d3
    bnes    .Le_trip
    bras    .Le_done                | never settled: the self-heal catches it
.Le_sampled:
    movel   USBCMD,%d0
    andil   #0xffffbfff,%d0
    movel   %d0,USBCMD
    tstl    %d1
    bnes    .Le_done                | still running: it follows the link
    bsr     out_oldest              | a0 = the oldest ACTIVE (this at worst)
.Le_prime:
    moveal  qh_out,%a1
    movel   %a0,%a1@(8)
    clrl    %a1@(12)
    movel   #EP3OUT_BIT,%d0
    movel   %d0,EPPRIME
.Le_done:
    rts

| The oldest ACTIVE dTD in queue order from out_ri -> a0 (d0 = 1), or d0 = 0.
| Clobbers d0/d1/d3/d4/a3.
out_oldest:
    mvzb    out_ri,%d4
    moveq   #NSLOTO-1,%d3
1:  movel   %d4,%d0
    bsr     out_slot
    movel   %a0@(4),%d1
    btst    #7,%d1
    bnes    2f
    addql   #1,%d4
    subql   #1,%d3
    bpls    1b
    moveq   #0,%d0
    rts
2:  moveq   #1,%d0
    rts

| Idle endpoint + queued dTD = prime the oldest, and count it.
out_selfheal:
    movel   ENDPTSTAT,%d0
    movel   EPPRIME,%d1
    orl     %d1,%d0
    andil   #EP3OUT_BIT,%d0
    bnes    9f
    bsr     out_oldest
    tstl    %d0
    beqs    9f
    moveal  qh_out,%a1
    movel   %a0,%a1@(8)
    clrl    %a1@(12)
    movel   #EP3OUT_BIT,%d0
    movel   %d0,EPPRIME
    addql   #1,out_reprimes
9:  rts

| 16 ring frames -> out_tx in DSP order, flag set. Before the cushion is
| full, and on an underrun (which refills the cushion), silence with the flag
| set: an open stream owns A-D even while it is starting.
out_build:
    moveal  #(out_tx+UNCACHED),%a1
    movel   out_produced,%d0
    subl    out_consumed,%d0        | fill
    movel   %d0,out_lastfill
    tstb    out_prefill
    beqs    1f
    cmpil   #OUT_TARGET,%d0
    bcs     .Lb_silence             | still filling
    clrb    out_prefill
    bras    2f
1:  cmpil   #BLOCK,%d0
    bcc     2f
    addql   #1,out_underruns
    moveq   #1,%d1
    moveb   %d1,out_prefill
    bras    .Lb_silence
2:  cmpl    out_minfill,%d0         | fill before this block's 16 go out
    bccs    4f
    movel   %d0,out_minfill
4:  cmpl    out_maxfill,%d0
    blss    5f
    movel   %d0,out_maxfill
5:  lea     out_ring,%a2
    movel   out_consumed,%d5
    moveq   #BLOCK,%d7
.Lb_frame:
    movel   %d5,%d0
    andil   #OUT_FRAMES-1,%d0
    lsll    #4,%d0
    lea     %a2@(0,%d0:l),%a0       | a0 = this frame: A B C D, 4 B each, LE
    lea     .Lb_order,%a3
    moveq   #4,%d6
.Lb_ch:
    mvzb    %a3@+,%d0               | subslot offset: C, D, A, B
    mvzb    %a0@(3,%d0:l),%d1       | sample[23:16]
    lsll    #8,%d1
    mvzb    %a0@(2,%d0:l),%d2       | sample[15:8]
    orl     %d2,%d1
    movew   %d1,%a1@+               | v[23:8]
    mvzb    %a0@(1,%d0:l),%d1       | sample[7:0]
    movew   %d1,%a1@+               | v[7:0]
    subql   #1,%d6
    bnes    .Lb_ch
    addql   #1,%d5
    subql   #1,%d7
    bnes    .Lb_frame
    movel   %d5,out_consumed
    bras    .Lb_flag
.Lb_silence:
    moveq   #TX_BYTES/4-1,%d1
3:  clrl    %a1@+
    subql   #1,%d1
    bpls    3b
.Lb_flag:
    moveal  #(out_tx+UNCACHED),%a1
    mvzw    %a1@(2),%d0
    oril    #FLAG,%d0
    movew   %d0,%a1@(2)
    rts
.Lb_order:
    .byte   8, 12, 0, 4             | DSP slots 0..3 = inputs C, D, A, B

| out_counter(i) -> d0 = the i-th long of out_counters (C ABI, argument on
| the stack). For the bench's `call`; a host reads them all with 0x56.
    .global out_counter
out_counter:
    movel   %sp@(4),%d0
    lsll    #2,%d0
    lea     out_counters,%a0
    movel   %a0@(0,%d0:l),%d0
    rts

    .data
    .balign 4
    .global out_counters
out_counters:                       | vendor request 0x56's order
out_produced:  .long 0              | frames into the ring
out_consumed:  .long 0              | frames sent to the DSP
out_pkts:      .long 0              | OUT packets retired
out_lastn:     .long 0              | frames in the last packet
out_lastfill:  .long 0              | ring fill at the last frame
out_underruns: .long 0              | frames the ring could not supply
out_overruns:  .long 0              | ring laps (host ahead)
out_reprimes:  .long 0              | self-heal primes
out_bad:       .long 0              | error / odd-length completions
out_frames:    .long 0              | frames (first state-7 visits)
out_seconds:   .long 0              | second state-7 visits (our DMA's completion)
out_minfill:   .long 0              | lowest fill while consuming, since up
out_maxfill:   .long 0              | highest fill while consuming, since up
qh_out:        .long 0
out_ring:      .space OUT_FRAMES*FRAME_B
out_alt:       .byte 0              | the host's request (USB interrupt)
out_running:   .byte 0              | EP3 OUT is up (state-7 owned)
out_prefill:   .byte 0              | filling the cushion
out_ri:        .byte 0              | next dTD slot to retire
out_busy:      .byte 0              | state 7: our transfer is in flight

    .balign 32
out_dtds:      .space NSLOTO*32
out_bufs:      .space NSLOTO*OPKT
out_tx:        .space TX_BYTES
