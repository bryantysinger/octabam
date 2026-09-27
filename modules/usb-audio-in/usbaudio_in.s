| usbaudio_in.s -- USB AUDIO IN: four channels from the host into inputs A-D.
|
| The host streams AudioStreaming interface 5 alt 1 on EP3 OUT: isochronous,
| asynchronous with IMPLICIT feedback (EP3 IN is the feedback source, so the
| host sizes each OUT packet from EP3 IN's), 4 channels x 24-bit in
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
| Memory: the dTDs and packet buffers are in on-chip SRAM (SRAM_* below,
| image 99): in SDRAM the controller lost the tail of about 1 packet in
| 2,000 idle and 1 in 200 under a busy project (image 97/98 on the unit,
| 26 Sep 2026; transaction error, 2-12 bytes short, rate rising with the
| firmware's load and with smaller RX bursts). The host-port buffer stays
| in SDRAM and is touched only through the uncached alias (+0x08000000),
| the rule usbaudio.s arrived at on hardware. The ring and the state are
| CPU-only.
|
| Latency: the ring runs at IN_TARGET frames of cushion. With implicit
| feedback the host's OUT rate follows EP3 IN's packet sizes, and those
| follow usbaudio's rate servo, which leaves the IN ring free to wander by
| its deadband (AUD_BAND, +-128 frames) before it steers. This ring
| mirrors that wander, and from wherever EP3 IN's fill sat when EP3 OUT's stream
| started it can swing by the band's full width, 256 frames. IN_TARGET =
| 384 (8.7 ms) covers that plus a block, a packet and margin. Under the port
| (26 Sep 2026, host IN and OUT in the same poll) 320 ran 24,000 polls with
| 0 underruns and one 8,000-poll run with 1, so 384 is the conservative
| pick until the unit's own min/max fill (vendor request 0x56 below) says
| how far it really swings. A tighter IN deadband is what would let it
| come down.
| SPDX-License-Identifier: MIT

.set UNCACHED,       0x08000000
| On-chip SRAM (RAMBAR1 0x80000235: 32 KB at 0x80000000, the backdoor
| (SPV) on, so the USB controller reaches it off the SDRAM bus). Image 99.
| The top 1 KB: the stock image's highest SRAM use is the 768-byte buffer
| at 0x80007574 (ends 0x80007874; 0x40098890), no module touches anything
| above 0x80006907, and under the port nothing above 0x80006924 was read or
| written (--touch-map, boot + frames + USB streaming, 26 Sep 2026). SRAM is
| not cached: no alias, and what the CPU writes is what the DMA reads.
| SCM BCR (MCF54455RM 14.2.6): lets the USB controller burst to and from
| the crossbar's slaves. It resets to 0 and neither the OS nor the
| bootloader sets it (the unit read 0). Device mode has ONE 16-byte RX
| FIFO (10.4.3); emptied a beat at a time it fell behind under a busy
| project and lost packet tails, which the controller reports as a CRC
| error (transaction error, 10.5.x). Measured on the unit, build 12,
| 26 Sep 2026, same busy session, one minute each: BCR 0 = 1,189 bad
| packets, BCR 0x3ff = 5. Set when EP3 OUT comes up and left on: it
| helps every USB transfer, EP3 IN included, and stock never relies on
| it being off.
.set SCM_BCR,        0xfc040024
.set BCR_ON,         0x000003ff     | GBR + GBW + all slaves (SBE 0xff)
| Crossbar arbitration (MCF54455RM ch. 15). With bursts on, 5-11 bad
| packets a minute were left (build 13, busy session). The USB controller is
| master 6, stock level 6 of 7 (PRS 0x65403210) under round robin (CRS
| 0x110) on every slave. On SDRAM (slave 2: the dQH list) and the SRAM
| backdoor (slave 4: our dTDs and buffers) it goes first under fixed
| priority, the others below it in their stock order; parking unchanged.
| Build 14 on the unit, same session, two minutes each: stock 11, this 0,
| no audible or UI change. A PRS write that puts two masters on one level
| is a bus error, so the value is written whole (it is valid; checked by
| tools/hw/usb_reg.py prs_ok) and before the CRS switch to fixed.
.set XBS_PRS2,       0xfc004200
.set XBS_CRS2,       0xfc004210
.set XBS_PRS4,       0xfc004400
.set XBS_CRS4,       0xfc004410
.set PRS_USB1ST,     0x60504321     | M6 USB 0, M0 core 1, M1 eDMA 2, M2 3, M3 4, M5 5, M7 6
.set CRS_FIXED,      0x10           | ARB 0 (fixed), PCTL 01 (park on last) as stock
.set SRAM_DTDS,      0x80007c00     | NSLOTI dTDs, 32-byte aligned (128 B)
.set SRAM_BUFS,      0x80007c80     | NSLOTI packet buffers (768 B)
.set SRAM_REPLY,     0x80007f80     | EP0 reply for 0x56 / 0x57 (128 B)

| ---- firmware sites (1.40C) ----
.set SETUP_ALT,      0x46c8ce0a     | SETUP wValue low = alt setting
.set SETUP_IFACE,    0x46c8ce0c     | SETUP wIndex low = interface number
.set SETUP_WVALH,    0x46c8ce0b     | SETUP wValue high
.set SETUP_WIDXH,    0x46c8ce0d     | SETUP wIndex high
.set SETUP_BMREQ,    0x46c8ce08     | SETUP bmRequestType
.set SETUP_BREQ,     0x46c8ce09     | SETUP bRequest
.set SETUP_WLENL,    0x46c8ce0e     | SETUP wLength low
.set SETUP_WLENH,    0x46c8ce0f     | SETUP wLength high
.set EP0_SEND_TAIL,  0x4001de5c     | jsr usb_ep0_send(len, buf); addq; done
.set EP0CTRL,        0xfc0b01c0     | ENDPTCTRL0
.set VENDOR_REQ,     0x56           | usbaudio answers 0x55 with its own
.set PEEK_REQ,       0x57           | vendor GET: read a peripheral register
.set POKE_LO,        0x58           | vendor OUT: write the low half of an in_poketab entry
.set POKE_HI,        0x59           | vendor OUT: the high half
.set POKE32,         0x5a           | vendor OUT: one 32-bit store, high half from 0x5b
.set POKE_STAGE,     0x5b           | vendor OUT: stage the high half for 0x5a
.set NPOKE,          18
.set NCOUNT,         28             | longs in in_counters
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
.set FRINDEX,    0xfc0b014c         | microframe index (EHCI layout: USBCMD+0x0c)
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
.set IN_IFACE,  5
.set NSLOTI,     4                  | dTDs kept queued (1 ms of packets)
.set OPKT,       192                | 12 frames x 16 B: the largest packet
.set FRAME_B,    16                 | 4 ch x 4 B
.set IN_FRAMES, 1024               | ring, frames (power of two)
.set IN_TARGET, 384                | cushion before consuming, 8.7 ms (see Latency)
.set BLOCK,      16                 | DSP frame
.set TX_BYTES,   256                | 128 halfwords to the DSP
.set FLAG,       0x0100             | stream flag, first low halfword

    .text
| ---- SET_INTERFACE (0x4001dd0a) ---------------------------------------------
| Displaced: oril #0x00400040,%d0 (d0 = ENDPTCTRL1, loaded by the stock
| movel or by usbaudio's shim). d1 is free until 0x4001dd2e reloads it.
    .global in_setiface_shim
in_setiface_shim:
    mvzb    SETUP_IFACE,%d1
    cmpil   #IN_IFACE,%d1
    beqs    1f
    oril    #0x00400040,%d0         | displaced
    jmp     SETIFACE_REJOIN
1:  mvzb    SETUP_ALT,%d1
    tstl    %d1
    beqs    2f
    moveq   #1,%d1                  | any non-zero alt is the streaming one
2:  moveb   %d1,in_alt             | the request; state 7 brings EP3 OUT up/down
    jsr     EP0_STATUS_IN
    jmp     SETIFACE_DONE

| ---- vendor GET 0x56 (installed at 0x4001de6e) ------------------------------
| Displaced: movel %d0,0xfc0b01c0 -- the stall's store (ENDPTCTRL0 with the
| stall bits already set in d0). Two paths reach it: the unknown-request tail
| (0x4001de6a's bset, which usbaudio's class shim also falls back into) and a
| standard-request stall (braw 0x4001de6e at 0x4001dd00). The bset site
| itself is 4 bytes and a 6-byte jmp there would cover that branch target.
| bmRequestType 0xc0 / bRequest 0x56 answers in_counters (NCOUNT big-endian
| longs) instead of stalling; everything else stalls as stock. wLength comes
| from the SETUP packet, not d2: d2 is wLength on usbaudio's path but not
| provably on the 0x4001dd00 one. d1 is dead here (both paths end in the
| handler's epilogue at 0x4001de74). The buffer is cached DRAM, the same as
| usbaudio's 0x55 counters, which read correctly on the unit (25 Sep 2026).
    .global in_ctrl_shim
in_ctrl_shim:
    movel   %d0,%d2                 | the stall value, for every reject path
    mvzb    SETUP_BMREQ,%d1         | d2/d3 are free: the epilogue at
    cmpil   #0xc0,%d1               | 0x4001de74 pops both
    beqs    .Lc_get
    cmpil   #0x40,%d1
    beq     .Lc_set
    bra     .Lc_stall
.Lc_get:
    mvzb    SETUP_BREQ,%d1
    cmpil   #VENDOR_REQ,%d1
    beqs    .Lc_counters
    cmpil   #PEEK_REQ,%d1
    bne     .Lc_stall
    | 0x57 peek (image 98): address = wIndex << 16 | wValue, a long in the
    | peripheral space 0xfc000000.. only, 4 bytes back. An address with no
    | register behind it may take an access error: read the ones you know.
    mvzb    SETUP_WIDXH,%d0
    lsll    #8,%d0
    mvzb    SETUP_IFACE,%d1
    orl     %d1,%d0
    swap    %d0
    mvzb    SETUP_WVALH,%d1
    lsll    #8,%d1
    orl     %d1,%d0
    mvzb    SETUP_ALT,%d1
    orl     %d1,%d0
    movel   %d0,%d1
    andil   #0xff000003,%d1
    cmpil   #0xfc000000,%d1
    bne     .Lc_stall
    moveal  %d0,%a0
    movel   %a0@,%d0
    movel   %d0,SRAM_REPLY
    pea     SRAM_REPLY
    moveq   #4,%d3
    bras    .Lc_send
.Lc_counters:
    lea     in_counters,%a0        | snapshot into SRAM: the EP0 DMA reads
    moveal  #SRAM_REPLY,%a1         | memory, and the counters live in the
    moveq   #NCOUNT-1,%d0           | data cache (the one-behind reads of 98)
1:  movel   %a0@+,%a1@+
    subql   #1,%d0
    bpls    1b
    pea     SRAM_REPLY
    moveq   #NCOUNT*4,%d3
.Lc_send:                           | buffer pushed, d3 = length
    mvzb    SETUP_WLENH,%d1
    lsll    #8,%d1
    mvzb    SETUP_WLENL,%d0
    orl     %d1,%d0                 | wLength
    cmpl    %d0,%d3
    bhis    1f                      | len > wLength: send wLength
    movel   %d3,%d0
1:  movel   %d0,%sp@-
    jmp     EP0_SEND_TAIL
.Lc_set:
    | 0x58 / 0x59 poke (image 98): wIndex = an entry of in_poketab (the
    | only registers this will write), wValue = the new low (0x58) or high
    | (0x59) half; the other half is kept. No data stage: ACK and done.
    | 0x5b / 0x5a (build 14): 0x5b stages wValue as a high half and writes
    | nothing; 0x5a then writes (staged << 16) | wValue in ONE 32-bit store.
    | For the XBS priority registers, which bus-error on any value giving two
    | masters one level -- every pair of half-writes passes through one.
    mvzb    SETUP_BREQ,%d1
    cmpil   #POKE_STAGE,%d1
    bnes    0f
    mvzb    SETUP_WVALH,%d3
    lsll    #8,%d3
    mvzb    SETUP_ALT,%d0
    orl     %d0,%d3
    movel   %d3,in_stage
    jsr     EP0_STATUS_IN
    jmp     SETIFACE_DONE
0:  cmpil   #POKE_LO,%d1
    beqs    1f
    cmpil   #POKE_HI,%d1
    beqs    1f
    cmpil   #POKE32,%d1
    bne     .Lc_stall
1:  mvzb    SETUP_WIDXH,%d0
    tstl    %d0
    bne     .Lc_stall
    mvzb    SETUP_IFACE,%d0         | wIndex low
    cmpil   #NPOKE,%d0
    bcc     .Lc_stall
    lsll    #2,%d0
    lea     in_poketab,%a0
    moveal  %a0@(0,%d0:l),%a0       | the register
    mvzb    SETUP_WVALH,%d3
    lsll    #8,%d3
    mvzb    SETUP_ALT,%d0
    orl     %d0,%d3                 | the 16-bit value
    cmpil   #POKE32,%d1
    bnes    4f
    movel   in_stage,%d0
    swap    %d0
    clrw    %d0
    orl     %d3,%d0                 | staged high : this low
    bras    3f
4:  movel   %a0@,%d0
    cmpil   #POKE_HI,%d1
    beqs    2f
    andil   #0xffff0000,%d0
    orl     %d3,%d0
    bras    3f
2:  andil   #0x0000ffff,%d0
    swap    %d3
    orl     %d3,%d0
3:  movel   %d0,%a0@
    jsr     EP0_STATUS_IN
    jmp     SETIFACE_DONE
.Lc_stall:
    movel   %d2,%d0
    movel   %d0,EP0CTRL             | displaced: the stall
    jmp     SETIFACE_DONE

| ---- state 7 (0x40004bc0) -----------------------------------------------------
| The transfer IRQ saved d0-d1/a0-a1; everything else is saved here.
    .global in_state7_shim
in_state7_shim:
    tstb    in_busy
    bnes    .Ls7_second
    moveq   #1,%d0
    moveb   %d0,in_busy
    lea     %sp@(-40),%sp
    moveml  %d2-%d7/%a2-%a5,%sp@
    bsr     in_frame
    moveml  %sp@,%d2-%d7/%a2-%a5
    lea     %sp@(40),%sp
    bsr     in_dma_start
    jmp     STATE7_DONE
.Ls7_second:
    addql   #1,in_seconds
    clrb    in_busy
    moveq   #1,%d1                  | stock state 7, displaced
    moveb   %d1,FRAME_UNMASK
    jmp     STATE7_DONE

| One more host-port transfer: 128 halfwords from in_tx to core 0 at $6320,
| eDMA ch 0 exactly as states 4/5 set it up.
in_dma_start:
    clrb    %d0
    moveb   %d0,CORE_SEL            | core 0
    moveq   #64,%d1
    movel   %d1,EDMA_NBYTES
    movel   #(in_tx+UNCACHED),%d1
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
in_frame:
    addql   #1,in_frames           | state-7 visits = DSP frames
    mvzb    in_alt,%d0
    mvzb    in_running,%d1
    cmpl    %d0,%d1
    beqs    1f
    tstl    %d0
    beqs    2f
    bsr     in_up
    bras    1f
2:  bsr     in_down
1:  tstb    in_running
    beqs    .Lf_idle
    movel   #EP3OUT_BIT,%d0
    movel   %d0,EPCOMPLETE          | W1C: no IOC, so this bit never interrupts
    bsr     in_retire
    bsr     in_selfheal
    bra     in_build
.Lf_idle:
    moveal  #(in_tx+UNCACHED),%a1
    clrl    %a1@                    | first sample's two halfwords: flag clear
    rts

| Bring EP3 OUT up. High speed only (the full-speed OUT alt is declared but
| not served: the IN side sends the stereo sum there). Stays down otherwise,
| and is retried every frame while the host asks for alt 1.
in_up:
    movel   PORTSC1,%d0
    andil   #0x0c000000,%d0
    cmpil   #0x08000000,%d0
    bne     9f
    bsr     in_flush
    bsr     in_qh_resolve          | a0 = EP3 OUT dQH
    moveq   #15,%d1
1:  clrl    %a0@+                   | the whole dQH: its token and pointers
    subql   #1,%d1                  | are power-on garbage (usbaudio.s)
    bpls    1b
    moveal  qh_in,%a0
    movel   #(0x60000000+(OPKT<<16)),%d0   | Mult 1, ZLT off, maxpkt 192
    | Mult must be non-zero here: image 96 (Mult 0, as Linux's chipidea udc
    | has for ISO RX) got a transaction error with 0 bytes on 800 of 821
    | packets and then stopped (26 Sep 2026).
    movel   %d0,%a0@
    moveq   #1,%d0
    movel   %d0,%a0@(8)             | next dTD: terminate
    movel   ENDPTCTRL3,%d0          | the RX half only: EP3 IN owns TX
    andil   #0xffff0000,%d0
    oril    #CTRL3_RX,%d0
    movel   %d0,ENDPTCTRL3
    movel   #BCR_ON,%d0             | USB bursts over the crossbar (see SCM_BCR)
    movel   %d0,SCM_BCR
    movel   #PRS_USB1ST,%d0         | USB first on SDRAM and the SRAM backdoor:
    movel   %d0,XBS_PRS2            | the priorities first (inert while the port
    movel   %d0,XBS_PRS4            | still round-robins), each ONE 32-bit store
    moveq   #CRS_FIXED,%d0
    movel   %d0,XBS_CRS2            | then fixed arbitration
    movel   %d0,XBS_CRS4
    clrl    in_produced
    clrl    in_consumed
    moveq   #-1,%d0
    movel   %d0,in_minfill
    clrl    in_maxfill
    moveq   #1,%d0
    moveb   %d0,in_prefill
    clrb    in_ri
    bsr     in_arm_all
    moveq   #1,%d0
    moveb   %d0,in_running
9:  rts

in_down:
    bsr     in_flush
    movel   ENDPTCTRL3,%d0
    andil   #0xffff0000,%d0         | RX half off, TX half as it was
    movel   %d0,ENDPTCTRL3
    moveal  #SRAM_DTDS,%a1
    moveq   #NSLOTI*8-1,%d1
1:  clrl    %a1@+
    subql   #1,%d1
    bpls    1b
    clrb    in_running
    rts

| Flush EP3 OUT, bounded, repeating while it still shows primed.
in_flush:
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
| list: the firmware's constant then). -> a0, cached in qh_in.
in_qh_resolve:
    movel   EPLISTADDR,%d0
    andil   #0xfffff800,%d0
    cmpil   #0x40000000,%d0
    blts    1f
    cmpil   #0x50000000,%d0
    blts    2f
1:  movel   #QH_LIST,%d0
2:  addil   #QH_EP3OUT_OFF,%d0
    movel   %d0,qh_in
    moveal  %d0,%a0
    rts

| d0 = slot (mod NSLOTI) -> a0 = its dTD, a3 = its buffer (both uncached).
| Clobbers d0/d1.
in_slot:
    andil   #NSLOTI-1,%d0
    movel   %d0,%d1
    lsll    #5,%d0
    moveal  #SRAM_DTDS,%a0
    addal   %d0,%a0
    moveal  #SRAM_BUFS,%a3
    lsll    #6,%d1                  | slot * 64
    addal   %d1,%a3
    addal   %d1,%a3
    addal   %d1,%a3                 | + slot * 192 (OPKT)
    rts

| Write slot d2's dTD for one packet: buffer pages, next = terminate, then
| the ACTIVE token LAST (uncached stores reach memory in program order).
| -> a0 = the dTD. Clobbers d0/d1/a3.
in_dtd_fill:
    movel   %d2,%d0
    bsr     in_slot
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

| Queue all NSLOTI dTDs as one chain and prime.
in_arm_all:
    moveq   #NSLOTI-1,%d2
1:  bsr     in_dtd_fill            | back to front: each links the next
    movel   %d2,%d0
    addql   #1,%d0
    cmpil   #NSLOTI,%d0
    beqs    2f
    moveal  %a0,%a4
    bsr     in_slot                | a0 = the next dTD
    movel   %a0,%a4@                | this.next = next
    moveal  %a4,%a0
2:  subql   #1,%d2
    bpls    1b
    moveal  qh_in,%a1              | a0 = slot 0, the head
    movel   %a0,%a1@(8)
    clrl    %a1@(12)
    movel   #EP3OUT_BIT,%d0
    movel   %d0,EPPRIME
    rts

| Retire completed dTDs in queue order into the ring, and queue each again.
in_retire:
    moveq   #NSLOTI,%d7             | at most one lap
.Lr_next:
    mvzb    in_ri,%d2
    movel   %d2,%d0
    bsr     in_slot
    movel   %a0@(4),%d3             | token
    btst    #7,%d3
    bne     .Lr_done                | still ACTIVE: nothing more has landed
    movel   %d3,%d0
    andil   #0x68,%d0               | halted, buffer error, transaction error
    beqs    1f
    addql   #1,in_bad
    addql   #1,in_err
    orl     %d0,in_errmask         | which of the three bits have been seen
    movel   %d3,in_lasttok         | diagnostic: the whole token of the last bad one
    movel   %d2,in_lastslot
    bsr     in_diag
1:  movel   %d3,%d0
    swap    %d0
    andil   #0x7fff,%d0             | bytes left
    movel   #OPKT,%d4
    subl    %d0,%d4                 | d4 = bytes received
    bcs     .Lr_requeue             | nonsense: drop it
    movel   %d4,%d0
    andil   #FRAME_B-1,%d0
    beqs    2f
    addql   #1,in_bad              | not whole frames
    addql   #1,in_partial
    movel   %d3,in_lasttok
    movel   %d2,in_lastslot
    movel   %d3,%d0
    andil   #0x68,%d0
    bnes    2f                      | in_diag already ran for this one
    bsr     in_diag
2:  bsr     in_scan                | diagnostic (build 11): non-zero data
    lsrl    #4,%d4                  | frames
    movel   %d4,in_lastn
    addql   #1,in_pkts
    tstl    %d4
    beqs    .Lr_requeue
    | copy d4 frames from a3 into the ring at in_produced
    lea     in_ring,%a2
    movel   in_produced,%d5
3:  movel   %d5,%d0
    andil   #IN_FRAMES-1,%d0
    lsll    #4,%d0
    lea     %a2@(0,%d0:l),%a1
    movel   %a3@+,%a1@+
    movel   %a3@+,%a1@+
    movel   %a3@+,%a1@+
    movel   %a3@+,%a1@+
    addql   #1,%d5
    subql   #1,%d4
    bnes    3b
    movel   %d5,in_produced
    subl    in_consumed,%d5        | fill
    cmpil   #IN_FRAMES,%d5
    blss    .Lr_requeue
    addql   #1,in_overruns         | host ahead by a whole ring: resync
    movel   in_produced,%d0
    subil   #IN_TARGET,%d0
    movel   %d0,in_consumed
.Lr_requeue:
    bsr     in_dtd_fill            | slot d2 again, ACTIVE
    bsr     in_enqueue
    movel   %d2,%d0
    addql   #1,%d0
    andil   #NSLOTI-1,%d0
    moveb   %d0,in_ri
    subql   #1,%d7
    bne     .Lr_next
.Lr_done:
    moveq   #NSLOTI,%d0             | diagnostic: dTDs retired in this pass
    subl    %d7,%d0
    cmpl    in_maxpass,%d0
    blss    1f
    movel   %d0,in_maxpass
1:  moveq   #3,%d1
    cmpl    %d1,%d0
    bcss    2f
    addql   #1,in_late             | 3 or 4 at once: state 7 came late
2:  rts

| Diagnostic (build 11): count the non-zero longs (and trailing bytes) in
| what this completion received. With the host sending digital silence a
| good packet is all zero; a bad one with non-zero data was corrupted on
| the way in (bit errors, the CRC failing at the end), one that is zero up
| to the cut was truncated clean. d4 = bytes received, d3 = token, a3 =
| the buffer. Clobbers d0/d5/d6/a1.
in_scan:
    moveal  %a3,%a1
    movel   %d4,%d5
    lsrl    #2,%d5                  | whole longs
    moveq   #0,%d6
    tstl    %d5
    beqs    3f
1:  tstl    %a1@+
    beqs    2f
    addql   #1,%d6
2:  subql   #1,%d5
    bnes    1b
3:  movel   %d4,%d5
    andil   #3,%d5                  | the 2-byte tail of a cut packet
    beqs    6f
4:  tstb    %a1@+
    beqs    5f
    addql   #1,%d6
5:  subql   #1,%d5
    bnes    4b
6:  tstl    %d6
    beqs    9f
    movel   %d3,%d0
    andil   #0x68,%d0
    bnes    7f
    addql   #1,in_good_nz          | a good packet with data in it
    bras    8f
7:  addql   #1,in_bad_nz           | a bad packet with data in it
    addl    %d6,in_bad_nzw
8:  movel   %d6,in_last_nzw
9:  rts

| Diagnostic for a bad completion (image 97): how many dTDs were still
| ACTIVE, and FRINDEX now and at the previous bad one (retire time, up to a
| DSP frame after the packet landed: the spacing is what is meaningful).
| Clobbers d0/d1/d6/a1.
in_diag:
    moveal  #(SRAM_DTDS+4),%a1
    moveq   #0,%d6
    moveq   #NSLOTI,%d1
5:  movel   %a1@,%d0
    btst    #7,%d0
    beqs    6f
    addql   #1,%d6
6:  lea     %a1@(32),%a1
    subql   #1,%d1
    bnes    5b
    movel   %d6,in_depth
    movel   in_badfr,%d0
    movel   %d0,in_badfr_prev
    movel   FRINDEX,%d0
    movel   %d0,in_badfr
    rts

| Append the just-filled dTD (a0, slot d2) after slot d2-1, the Chipidea
| add-dTD procedure (usbaudio.s audio_pkt_build has the commentary).
| Clobbers d0/d1/d3/a1/a3/a4/a5.
in_enqueue:
    moveal  %a0,%a5                 | this
    movel   %d2,%d0
    subql   #1,%d0
    bsr     in_slot                | a0 = previous
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
    bsr     in_oldest              | a0 = the oldest ACTIVE (this at worst)
.Le_prime:
    addql   #1,in_dry              | diagnostic: the endpoint had no dTD left
    moveal  qh_in,%a1
    movel   %a0,%a1@(8)
    clrl    %a1@(12)
    movel   #EP3OUT_BIT,%d0
    movel   %d0,EPPRIME
.Le_done:
    rts

| The oldest ACTIVE dTD in queue order from in_ri -> a0 (d0 = 1), or d0 = 0.
| Clobbers d0/d1/d3/d4/a3.
in_oldest:
    mvzb    in_ri,%d4
    moveq   #NSLOTI-1,%d3
1:  movel   %d4,%d0
    bsr     in_slot
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
in_selfheal:
    movel   ENDPTSTAT,%d0
    movel   EPPRIME,%d1
    orl     %d1,%d0
    andil   #EP3OUT_BIT,%d0
    bnes    9f
    bsr     in_oldest
    tstl    %d0
    beqs    9f
    moveal  qh_in,%a1
    movel   %a0,%a1@(8)
    clrl    %a1@(12)
    movel   #EP3OUT_BIT,%d0
    movel   %d0,EPPRIME
    addql   #1,in_reprimes
9:  rts

| 16 ring frames -> in_tx in DSP order, flag set. Before the cushion is
| full, and on an underrun (which refills the cushion), silence with the flag
| set: an open stream owns A-D even while it is starting.
in_build:
    moveal  #(in_tx+UNCACHED),%a1
    movel   in_produced,%d0
    subl    in_consumed,%d0        | fill
    movel   %d0,in_lastfill
    tstb    in_prefill
    beqs    1f
    cmpil   #IN_TARGET,%d0
    bcs     .Lb_silence             | still filling
    clrb    in_prefill
    bras    2f
1:  cmpil   #BLOCK,%d0
    bcc     2f
    addql   #1,in_underruns
    moveq   #1,%d1
    moveb   %d1,in_prefill
    bras    .Lb_silence
2:  cmpl    in_minfill,%d0         | fill before this block's 16 go out
    bccs    4f
    movel   %d0,in_minfill
4:  cmpl    in_maxfill,%d0
    blss    5f
    movel   %d0,in_maxfill
5:  lea     in_ring,%a2
    movel   in_consumed,%d5
    moveq   #BLOCK,%d7
.Lb_frame:
    movel   %d5,%d0
    andil   #IN_FRAMES-1,%d0
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
    movel   %d5,in_consumed
    bras    .Lb_flag
.Lb_silence:
    moveq   #TX_BYTES/4-1,%d1
3:  clrl    %a1@+
    subql   #1,%d1
    bpls    3b
.Lb_flag:
    moveal  #(in_tx+UNCACHED),%a1
    mvzw    %a1@(2),%d0
    oril    #FLAG,%d0
    movew   %d0,%a1@(2)
    rts
.Lb_order:
    .byte   8, 12, 0, 4             | DSP slots 0..3 = inputs C, D, A, B

| in_counter(i) -> d0 = the i-th long of in_counters (C ABI, argument on
| the stack). For the bench's `call`; a host reads them all with 0x56.
    .global in_counter
in_counter:
    movel   %sp@(4),%d0
    lsll    #2,%d0
    lea     in_counters,%a0
    movel   %a0@(0,%d0:l),%d0
    rts

    .data
    .balign 4
    .global in_counters
in_counters:                       | vendor request 0x56's order
in_produced:  .long 0              | frames into the ring
in_consumed:  .long 0              | frames sent to the DSP
in_pkts:      .long 0              | OUT packets retired
in_lastn:     .long 0              | frames in the last packet
in_lastfill:  .long 0              | ring fill at the last frame
in_underruns: .long 0              | frames the ring could not supply
in_overruns:  .long 0              | ring laps (host ahead)
in_reprimes:  .long 0              | self-heal primes
in_bad:       .long 0              | error / odd-length completions
in_frames:    .long 0              | frames (first state-7 visits)
in_seconds:   .long 0              | second state-7 visits (our DMA's completion)
in_minfill:   .long 0              | lowest fill while consuming, since up
in_maxfill:   .long 0              | highest fill while consuming, since up
in_err:       .long 0              | completions with an error bit (diagnostic, image 95)
in_partial:   .long 0              | completions that were not whole frames
in_errmask:   .long 0              | OR of the error bits seen: 0x40 halted, 0x20 buffer, 0x08 transaction
in_lasttok:   .long 0              | the last bad completion's dTD token (bytes left in 30:16)
in_lastslot:  .long 0              | and its dTD slot (0..3)
in_depth:     .long 0              | dTDs still ACTIVE at the last bad one (image 97)
in_badfr:     .long 0              | FRINDEX at the last bad one
in_badfr_prev:.long 0              | FRINDEX at the one before
in_dry:       .long 0              | enqueues that found the endpoint's list empty
in_late:      .long 0              | retire passes that found 3+ dTDs done
in_maxpass:   .long 0              | most dTDs done in one pass
in_good_nz:   .long 0              | good packets with non-zero data (build 11)
in_bad_nz:    .long 0              | bad packets with non-zero data
in_bad_nzw:   .long 0              | non-zero longs/bytes summed over those
in_last_nzw:  .long 0              | non-zero longs/bytes in the last such packet
in_stage:     .long 0              | 0x5b's staged high half (not a counter)

| The registers 0x58/0x59 may write (image 98), by wIndex:
in_poketab:
    .long   0xfc0b01a8              | 0 USBMODE (stock 0x0e; SDIS = 0x10)
    .long   0xfc0b0160              | 1 BURSTSIZE (stock never writes it)
    .long   0xfc0b0164              | 2 TXFILLTUNING (nor this)
    .long   0xfc004100, 0xfc004200, 0xfc004300, 0xfc004400   | 3-9 XBS PRS1..7
    .long   0xfc004500, 0xfc004600, 0xfc004700
    .long   0xfc004110, 0xfc004210, 0xfc004310, 0xfc004410   | 10-16 XBS CRS1..7
    .long   0xfc004510, 0xfc004610, 0xfc004710              | (stock 0x110 on all)
    .long   0xfc040024              | 17 SCM BCR: USB bursts to/from the crossbar (reset 0 = off;
                                    |    the unit reads 0, build 11; 0x3ff = read + write + all slaves)
qh_in:        .long 0
in_ring:      .space IN_FRAMES*FRAME_B
in_alt:       .byte 0              | the host's request (USB interrupt)
in_running:   .byte 0              | EP3 OUT is up (state-7 owned)
in_prefill:   .byte 0              | filling the cushion
in_ri:        .byte 0              | next dTD slot to retire
in_busy:      .byte 0              | state 7: our transfer is in flight

    .balign 32
in_tx:        .space TX_BYTES
