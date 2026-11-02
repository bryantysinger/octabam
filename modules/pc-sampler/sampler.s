| PC SAMPLER -- a statistical profiler of the ColdFire on the unit: PIT3
| (0xfc08c000, the one PIT the firmware never touches; INTC1 source 46,
| vector 0xae) interrupts at about 20 kHz at level 6, and its handler counts
| the interrupted PC into a histogram. Level 6 reaches inside the frame
| interrupt (level 5), so the histogram is where the CPU's TIME goes, memory
| stalls included -- what the port's instruction counts cannot show. Not
| level 7: it is non-maskable, and under the port it re-entered its own
| handler until the stack ran through memory. So the level-6 eDMA handler
| and 0x2700 critical sections are not sampled inside: a tick that lands
| there is taken when they end, counted against the next instruction.
|
| Histograms (longs, counts since boot; the host diffs two reads):
|   pcs_lo   stock code 0x40000400..0x40020400 (the frame path, the kernel, the tasks), 32 bytes a bucket (4096)
|   pcs_hi   0x40a80000..0x40b00000 (octabam's runtime), 128 bytes a bucket (4096)
|   pcs_other a PC in neither range; pcs_ipl[8] by the interrupted context's IPL
| pcs_hdr (published as PCS_HDR; USB 0xc0/0x57 block 6, 64 bytes) says where
| they are, so tools/hw/pc_sampler.py reads them with 0xc0/0x59.
|
| Started from the sys task's init (the detour on 0x40040482, where it
| installs DTIM1's handler): the vector is written to the VBR table
| (0x40000000, KERNEL.md) after the kernel's refill, then ICR46 = 6, CIMR =
| 46, then the PIT. The handler touches only its own words.
| SPDX-License-Identifier: MIT
        .equ    PIT3,     0xfc08c000            | PCSR (16), PMR +2 (16)
        .equ    ICR46,    0xfc04c06e            | INTC1 + 0x40 + 46
        .equ    CIMR1,    0xfc04c01d
        .equ    VEC,      0xae                  | INTC1 vector base 0x80 + 46
        .equ    PCSR_RUN, 0x001b                | PRE 0 (bus/1), OVW, PIE, RLD, EN
        .equ    PCSR_ACK, 0x001f                | the same + PIF (write 1 to clear)
        .equ    PMR,      6607                  | 132 MHz / 6608 = 19,976 Hz
        .equ    LO_BASE,  0x40000400
        .equ    LO_SPAN,  0x20000
        .equ    LO_SHIFT, 5
        .equ    HI_BASE,  0x40a80000
        .equ    HI_SPAN,  0x80000
        .equ    HI_SHIFT, 7

        .text
        .globl  pcs_init, pcs_isr
| jsr'd in place of `jsr 0x40000d50` at 0x40040482 (DTIM1's install, its
| two arguments on the stack): start the sampler, then go on to the install
| with the caller's return address where it was.
pcs_init:
        lea     -8(%sp),%sp
        movem.l %d0/%a0,(%sp)
        move.l  #pcs_isr,%d0
        move.l  %d0,0x40000000+4*VEC
        moveq   #6,%d0
        move.b  %d0,ICR46
        moveq   #46,%d0
        move.b  %d0,CIMR1
        move.l  #PMR,%d0
        move.w  %d0,PIT3+2
        move.l  #PCSR_RUN,%d0
        move.w  %d0,PIT3
        movem.l (%sp),%d0/%a0
        lea     8(%sp),%sp
        jmp     0x40000d50                      | displaced: jsr 0x40000d50

| Level 6. The exception frame: 0(sp) format/vector, 2(sp) SR, 4(sp) PC.
pcs_isr:
        lea     -12(%sp),%sp
        movem.l %d0-%d1/%a0,(%sp)
        moveq   #PCSR_ACK,%d0
        move.w  %d0,PIT3
        addq.l  #1,pcs_total
        move.w  14(%sp),%d0                     | the interrupted SR
        lsr.l   #8,%d0
        moveq   #7,%d1
        and.l   %d1,%d0
        lea     pcs_ipl,%a0
        addq.l  #1,(%a0,%d0.l*4)
        move.l  16(%sp),%d0                     | the interrupted PC
        move.l  %d0,%d1
        sub.l   #LO_BASE,%d1
        cmp.l   #LO_SPAN,%d1
        bcc.s   1f
        lsr.l   #LO_SHIFT,%d1
        lea     pcs_lo,%a0
        addq.l  #1,(%a0,%d1.l*4)
        bra.s   9f
1:      move.l  %d0,%d1
        sub.l   #HI_BASE,%d1
        cmp.l   #HI_SPAN,%d1
        bcc.s   2f
        lsr.l   #HI_SHIFT,%d1
        lea     pcs_hi,%a0
        addq.l  #1,(%a0,%d1.l*4)
        bra.s   9f
2:      addq.l  #1,pcs_other
9:      movem.l (%sp),%d0-%d1/%a0
        lea     12(%sp),%sp
        rte

        .data
        .balign 4
        .globl  pcs_hdr, PCS_HDR
| 64 bytes: magic 'PCS1', total, other, rate (Hz), lo base, lo bucket bytes,
| lo count, lo address, hi base, hi bucket bytes, hi count, hi address,
| ipl address, then three spare longs
PCS_HDR:
pcs_hdr:
        .long   0x50435331
pcs_total:  .long 0
pcs_other:  .long 0
        .long   132000000/(PMR+1)
        .long   LO_BASE, 1<<LO_SHIFT, LO_SPAN>>LO_SHIFT, pcs_lo
        .long   HI_BASE, 1<<HI_SHIFT, HI_SPAN>>HI_SHIFT, pcs_hi
        .long   pcs_ipl, 0, 0, 0
pcs_ipl:    .space  32
        .bss
        .balign 4
pcs_lo:     .space  (LO_SPAN>>LO_SHIFT)*4
pcs_hi:     .space  (HI_SPAN>>HI_SHIFT)*4
