| CC -> FX2 PAGE-2 cave (OS 1.40C, ColdFire) -- and, since 13 Sep 2026, FX1 too.
|
| Stock CC only reaches FX2 page 1 (CC 40-45; the handler admits cc-16 < 30).
| This cave adds CC 62-67 -> the host's bus-engine page-2 slots 6-11, and
| CC 68-73 -> the track's FX1 station's page-2 slots 6-11 (13 Sep 2026), so
| the voicing round can drive every control over MIDI, not just page 1.
|
| FX1 (CC 68-73): mirrors the FX1 PAGE-2 EDITOR 0x4003abe4 store for store
| (disassembled 13 Sep 2026): Part DB+part*6322+track*30+slot+0x8f07e
| (0x4003acb2), shadow 0x100a51cc+part*6322+track*30+slot (0x4003acba), the
| four dirty flags (0x4003acbe..0x4003acec, the same four the FX2 editor
| writes), and the live lane 0x80000842+track*72+slot (0x4003ad08 -- lane
| +0x32, the FX1 page-2 block the per-frame copier delivers to the DSP). The
| clamp is the editor's own: min at desc+0x6a+4*(slot+6), count at
| desc+0x9a+4*(slot+6), desc = 0x400d5f58[the Part's FX1 id at +0x8ed80+track]
| (0x4003ac68..0x4003ac8c). An FX1 id of 0 (NONE) writes nothing: the editor
| never runs for NONE because that page draws no knob, and on this image id 0
| runs SEND with whatever bytes are there. The editor's
| jsr 0x40027e00 (the refresher) and its per-slot redraw marker are not
| mirrored, as for FX2: off-page there is no knob to redraw.
|
| HOOK: the MIDI dispatch table 0x400d6474[0xB] (CC) is repointed from the
| stock handler 0x4000e79c to CAVE. CAVE reads the CC number; anything but
| 62-73 tail-calls stock (jmp 0x4000e79c) with the argument intact, so no
| stock CC is disturbed. Only 62-73 are handled here.
|
| WRITE: mirrors the busscreen's measured page-2 write, generalised over
| track -- Part, live byte and mirror, count-clamped. It does NOT call the
| page-2 editor 0x4003a474 and does NOT touch the TRACKB global: that editor
| writes the same live byte + mirror directly and nothing in 0x40171xxx
| (traced 5 Sep 2026, docs/firmware/midi_re_cc.md), so a direct write reproduces its
| stores without the cross-task TRACKB race. Off-page there is no knob to
| redraw, so the redraw marker is skipped too.
|
| Track resolution mirrors the stock CC 16-45 handler (0x4000e91c): rebuild
| the channel->track map, gate on AUDIO CC IN, and write every audio track
| (0-7) whose trig channel is this message's channel. Auto-channel / MIDI_MODE
| retargeting is not handled (it maps to MIDI tracks, which host no FX2).
|
| Clamp uses per-engine page-2 count tables (VCOUNT/DCOUNT, 6 bytes each,
| slot2 order) patched by the build; a select's over-count value would be the
| stored index that stalls the sequencer, so the clamp is mandatory.

| CC_NEXT is where anything but 62-67 goes: the stock CC handler
| (0x4000e79c), or -- when Octakit is in the image and the scenes-kits
| bridge chains this cave in front of her CC dispatch -- her handler. The
| build defines it (CavePatch.defsyms; schema.Override); it is not set here.
        .set    P1WRITE,  0x40054cd8   | stock page-1 writer (canary, CC 67 only)
        .set    MAPBUILD, 0x40001854   | fills the channel->track map
        .set    MAPGLOB,  0x46104cf4   | long stock loads to d3 before MAPBUILD
        .set    CHANMASK, 0x46c7febe   | [16] u32, one mask per channel
        .set    CCIN,     0x80000049   | AUDIO CC IN (bit 0)
        .set    IDLIVE,   0x80000ecc   | per-track live FX2 id (chooser-filled; unused now)
        .set    IDOFF,    0x8ed88      | Part: per-track FX2 id byte (+track)
        .set    DBPTR,    0x46c82456   | long: the Part DB base
        .set    PARTB,    0x80000003   | byte: part index -- the one the PAGE-2
                                       | editor P2EDIT uses (0x4003a4a8). The
                                       | page-1 writer uses 0x100b14cf instead;
                                       | builds 96-98 followed that and wrote the
                                       | wrong part's page-2 store when they differ.
        .set    P2OFF,    0x8f084      | FX2 page-2 Part store: DB+part*6322+track*30+slot2
                                       | + 0x8f084 -- the FX2 PAGE-2 EDITOR's own store
                                       | (0x4003aaaa, disassembled 13 Sep 2026). 0x8ef5a,
                                       | used until then, is the PLAYBACK page-2 array of
                                       | the machine-index editor 0x4003a474 (its
                                       | "staged index" 0x460d5c30 is the MACHINE type):
                                       | a CC there corrupted the track's playback page 2.
        .set    DISPOFF,  0x8f084      | the same byte (kept: the FX2 dial READS it)
        .set    LIVEB,    0x80000810    | live block base
        .set    MIRRB,    0x100a50c0   | (old, part-0 view of SHADOW+24; unused)
        .set    SHADOW,   0x100a51d2   | FX2 page-2 shadow: +part*6322+track*30+slot2 (FX2 editor 0x4003aab2; 0x100a50a8 was the PLAYBACK editor's)
        .set    CHGBITS,  0x95048      | DB+: part-changed bitmask |= 1<<part (0x4003a5ca)
        .set    MODBITS,  0x100b145e   | byte: |= 1<<part (0x4003a5e2)
        .set    CHGFLAG,  0x9b332      | DB+: long "changed" = 1 (0x4003a5f0) -> refresh
        .set    GCHG,     0x100f8598   | long: global "changed" = 1 (0x4003a5f4)
        .set    FX2P2,    0            | no page term: the FX2 page-2 arrays are per track (30 B), slot2 direct
        .set    VERBID,   7            | BusVerb FX2 id
        .set    DLYID,    6            | BusDelay FX2 id
        .set    ID1OFF,   0x8ed80      | Part: per-track FX1 id byte (+track) (FX1 editor 0x4003ac1e)
        .set    DESC1,    0x400d5f58   | FX1 descriptor table [id] (0x4003ac26)
        .set    P1P2OFF,  0x8f07e      | FX1 page-2 Part store: DB+part*6322+track*30+slot (0x4003acac)
        .set    SHADOW1,  0x100a51cc   | FX1 page-2 shadow: +part*6322+track*30+slot (0x4003acb4)
        .set    LANE1,    0x32         | FX1 page-2 live lane offset in the 72-byte block (0x80000842)
| VCOUNT / DCOUNT are the two count tables at the END of this file: the
| linker resolves `lea VCOUNT,%a1` to wherever the build places the cave
| (until 9 Sep 2026 they were 0x40bad000/4 placeholders patched by hand).

        .text
| ---- CAVE(msg): dispatch entry (jsr'd), msg* at %sp@(4) ------------------
CAVE:   movel   %sp@(4),%a0            | a0 = msg {status, cc, value}
        moveq   #0,%d0
        moveb   %a0@(1),%d0            | d0 = CC number
        subil   #62,%d0                | d0 = cc - 62
        moveq   #11,%d1
        cmpl    %d0,%d1                | 11 - (cc-62); carry if 11 < (cc-62)
        bcs.s   tostk                  | not 62..73 (also catches cc < 62)
        bra.s   mine
tostk:  jmp     (CC_NEXT).l            | tail-call the next handler, argument intact

mine:   lea     %sp@(-28),%sp
        movem.l %d2-%d7/%a2,%sp@
        movel   %d0,%d4                | d4 = cc-62: 0..5 = FX2 slot2, 6..11 = FX1 slot2+6 -- MAPBUILD preserves d2-d4/a2 only
        moveal  %a0,%a2                | a2 = msg (preserved across MAPBUILD)
        movel   MAPGLOB,%d3            | mimic stock register environment
        jsr     MAPBUILD               | rebuild CHANMASK[16]. ⚠️ CLOBBERS d5-d7: it
                                       | saves only d2-d4/a2 (0x40001858). The value
                                       | used to be loaded into d5 BEFORE this call;
                                       | the emu's channel loop never ran so it
                                       | survived, hardware trashed it (build 94/95).
        moveq   #0,%d5
        moveb   %a2@(2),%d5            | d5 = value, loaded AFTER the call
        andil   #0x7f,%d5
        tstb    CCIN                   | any non-zero = on, exactly as stock
        beq.s   done                   | (0x4000e962 tstb/bne); a mask on bit 0
                                       | would silently skip if the flag byte
                                       | holds another value
        moveq   #0,%d0
        moveb   %a2@,%d0
        andil   #15,%d0                | channel = status & 15
        lea     CHANMASK,%a0
        movel   %a0@(0,%d0:l:4),%d7    | d7 = this channel's track mask
        moveq   #0,%d6                 | d6 = track
tloop:  moveq   #1,%d0
        lsll    %d6,%d0
        andl    %d7,%d0
        beq.s   tnext                  | track d6 not on this channel
        bsr.s   wtrack
tnext:  addql   #1,%d6
        moveq   #8,%d0
        cmpl    %d6,%d0
        bgt.s   tloop
done:   movem.l %sp@,%d2-%d7/%a2
        lea     %sp@(28),%sp
        rts

| ---- wtrack: write page-2 slot d4 = value d5 for track d6 ----------------
| reads d4/d5/d6, preserves d4/d5/d6/d7/a2; scratches d0-d3/a0/a1.
| d4 >= 6 is an FX1 CC (68-73): the block at the end of this file.
wtrack: moveq   #6,%d1
        cmpl    %d4,%d1                | 6 - d4: le when d4 >= 6
        ble.w   wtrk1
        movel   DBPTR,%d0
        moveq   #0,%d1
        moveb   PARTB,%d1
        movel   #6322,%d3
        mulu.l  %d3,%d1
        addl    %d1,%d0                | d0 = DB + part*6322
        moveal  %d0,%a0
        addal   #IDOFF,%a0
        addal   %d6,%a0
        moveq   #0,%d0
        moveb   %a0@,%d0               | the PART's FX2 id for track d6 (what the
                                       | busscreen's edit path reads, IDOFF). The
                                       | live mirror 0x80000ecc is filled by the
                                       | chooser; a hidden engine is never chosen
                                       | there, so it can read 0 and skip the track.
        moveq   #DLYID,%d1
        cmpl    %d0,%d1
        beq.s   wdly
        moveq   #VERBID,%d1
        cmpl    %d0,%d1
        beq.s   wverb
        rts                            | not a bus host -> skip this track
wverb:  lea     VCOUNT:l,%a1           | :l = absolute long, as the hand-patched
        bra.s   wclamp                 | placeholder form was; a same-section
wdly:   lea     DCOUNT:l,%a1           | label would otherwise assemble pc-relative
                                       | (2 bytes shorter) and break identity
wclamp: moveq   #0,%d1
        moveb   %a1@(0,%d4:l),%d1      | count (1..128)
        subql   #1,%d1                 | max = count - 1
        movel   %d5,%d2                | value
        cmpl    %d1,%d2                | max - value; lt if value > max
        ble.s   wpos
        movel   %d1,%d2                | clamp to max
wpos:   | d2 = clamped value (>=0 by construction)
        | Part = DB + part*6322 + P2OFF + track*30 + 18 + slot2
        movel   DBPTR,%d0
        moveq   #0,%d1
        moveb   PARTB,%d1
        movel   #6322,%d3
        mulu.l  %d3,%d1
        addl    %d1,%d0                | d0 = DB + part*6322
        | + page*6: P2EDIT forms DB+part*6322+0x8ef5a+track*30+page*6+slot2 with
        | page = the staged index 0x460d5c30. The FX2 page stages index 3
        | (button 4 -> 3 remap at 0x4005a5cc), so the FX2 page-2 store is +18 --
        | the busscreen's original value, hardware-confirmed 5 Sep 2026: build
        | 100 read the index live with the page up and page 2 moved over CC;
        | builds 97-99 hardcoded 4 (+24) and never took. Pinned so it works
        | with the FX2 page NOT on screen (the voicing case).
        | + page*6 where page = the staged index 0x460d5c30 (P2EDIT 0x4003a4b4).
        | ⚠️ 13 Sep 2026: the block below is the HISTORY of a wrong model. The
        | "staged index" belongs to the PLAYBACK page-2 editor (it is the machine
        | type); the FX2 page-2 editor at 0x4003a9dc..0x4003ab1a has no page term.
        | SHMR "moved over CC" on 5 Sep because the DISPOFF write below hit the real
        | FX2 Part byte (0x8f084) by accident; the P2OFF/live/shadow writes went to
        | PLAYBACK's arrays. Now all three target the FX2 editor's own stores.
        | MEASURED 5 Sep 2026: with the FX2 page up the staged index is 0 --
        | tag 12 wrote index*16 into GATE and the dial sat at zero, while MODE
        | and SHMR moved over CC. So the FX2 page-2 store is +0 + slot2. The
        | busscreen's +18 and my +24 (page kind 3/4 * 6) were both wrong; tags
        | 11 (+18) and 97-99 (+24) never took, tags 10/12 (live index) did.
        | Pinned so it works with the FX2 page NOT on screen (the voicing case).
        moveq   #FX2P2,%d1
        addl    %d1,%d0                | d0 = DB + part*6322 + 0
        moveal  %d0,%a0
        addal   #P2OFF,%a0
        movel   %d6,%d1
        moveq   #30,%d3
        mulu.l  %d3,%d1                | track*30
        addal   %d1,%a0
        addal   %d4,%a0
        moveb   %d2,%a0@               | Part <- value
        | display = base + DISPOFF + track*30 + 6 + slot2 -- the byte the stock
        | FX2 dial READS (0x8f084, confirmed by an emu read-hook). d0 still
        | holds base, d1 still holds track*30 from the Part write above.
        moveal  %d0,%a0
        addal   #DISPOFF,%a0
        addal   %d1,%a0                | (page*6 already in the base)
        addal   %d4,%a0
        moveb   %d2,%a0@               | displayed value <- value
        | live = LIVEB + track*72 + 0x38 + slot2 -- the FX2 page-2 lane the per-frame
        | copier 0x4000cae8 delivers to the DSP record (measured under the port 13 Sep
        | 2026: +0x2c AMP, +0x32 FX1, +0x38 FX2; +0x20 is PLAYBACK's and never reaches
        | the DSP -- the FX2 editor writes 0x80000848+track*72+slot2 at 0x4003ab00)
        movel   %d6,%d1
        moveq   #72,%d3
        mulu.l  %d3,%d1
        lea     LIVEB,%a0
        addal   %d1,%a0
        addal   #0x38,%a0
        addal   %d4,%a0
        moveb   %d2,%a0@
        | shadow = SHADOW + part*6322 + track*30 + slot2   (d0 still = DB+part*6322)
        movel   %d6,%d3
        moveq   #30,%d1
        mulu.l  %d1,%d3                | d3 = track*30
        movel   %d0,%d1
        subl    DBPTR,%d1              | d1 = part*6322 + page*6
        addl    %d3,%d1
        addil   #SHADOW,%d1
        moveal  %d1,%a0
        addal   %d4,%a0
        moveb   %d2,%a0@               | shadow <- value
        | mark the part changed, exactly as P2EDIT does after its stores
        | (0x4003a5c6..0x4003a5f0). P2EDIT posts nothing to the DSP: page-2 is
        | picked up by a refresh that this flag triggers, rebuilding the frame
        | (and the page cache) from the Part store. Without it the store is inert.
        moveq   #0,%d1
        moveb   PARTB,%d1
        moveq   #1,%d3
        lsll    %d1,%d3                | d3 = 1 << part
        moveal  DBPTR,%a0              | a0 = DB
        moveal  %a0,%a1
        addal   #CHGBITS,%a1
        moveb   %a1@,%d1
        orl     %d3,%d1
        moveb   %d1,%a1@               | DB+0x95048 |= 1<<part
        moveb   MODBITS,%d1
        orl     %d3,%d1
        moveb   %d1,MODBITS            | 0x100b145e |= 1<<part
        addal   #CHGFLAG,%a0
        moveq   #1,%d1
        movel   %d1,%a0@               | DB+0x9b332 = 1
        movel   %d1,GCHG               | 0x100f8598 = 1 -- the GLOBAL changed flag
                                       | (P2EDIT 0x4003a5f4). Emu write-diff of
                                       | P2EDIT vs this cave (5 Sep): this was the
                                       | only functional store still missing.
        rts

| ---- wtrk1: FX1 page-2 slot (d4-6) = value d5 for track d6 (13 Sep 2026) --
| The FX1 PAGE-2 EDITOR 0x4003abe4, store for store, minus the refresher
| call and the redraw marker (see the header). Reads d4/d5/d6, preserves
| d4/d5/d6/d7/a2; scratches d0-d3/a0/a1.
wtrk1:  movel   DBPTR,%d0
        moveq   #0,%d1
        moveb   PARTB,%d1
        movel   #6322,%d3
        mulu.l  %d3,%d1
        addl    %d1,%d0                | d0 = DB + part*6322
        moveal  %d0,%a0
        addal   #ID1OFF,%a0
        addal   %d6,%a0
        moveq   #0,%d1
        moveb   %a0@,%d1               | the Part's FX1 id for track d6 (0x4003ac24)
        beq.w   w1skip                 | NONE (id 0): no page of ours -- write nothing.
                                       | (The editor never runs for NONE: that page
                                       | draws no knob. Its descriptor's counts are
                                       | not 0, so an id test is the honest guard.)
        lea     DESC1,%a1
        moveal  %a1@(0,%d1:l:4),%a1    | a1 = its descriptor (0x4003ac2c)
        movel   %d4,%d3                | d3 = (cc-62) = slot2 + 6: the page-2 slot index 6..11
        lea     %a1@(0,%d3:l:4),%a0    | a0 = desc + 4*(slot2+6)
        movel   %a0@(154),%d1          | count  (desc+0x9a+4*(slot2+6), 0x4003ac80)
        movel   %a0@(106),%d3          | min    (desc+0x6a+4*(slot2+6), 0x4003ac68)
        addl    %d3,%d1
        subql   #1,%d1                 | d1 = max = min + count - 1
        movel   %d5,%d2                | value
        cmpl    %d3,%d2                | value - min
        bge.s   w1lo
        movel   %d3,%d2                | below min -> min  (0x4003ac70..74)
w1lo:   cmpl    %d1,%d2                | max - value
        ble.s   w1ok
        movel   %d1,%d2                | above max -> max  (0x4003ac88..8c)
w1ok:   | d2 = clamped value; d0 = DB + part*6322
        movel   %d6,%d1
        moveq   #30,%d3
        mulu.l  %d3,%d1                | d1 = track*30
        movel   %d4,%d3
        subql   #6,%d3                 | d3 = slot2 (0..5)
        moveal  %d0,%a0
        addal   %d1,%a0
        addal   %d3,%a0
        addal   #P1P2OFF,%a0
        moveb   %d2,%a0@               | Part <- value (0x4003acb2)
        movel   %d0,%a1
        subl    DBPTR,%a1              | a1 = part*6322
        addal   %d1,%a1                | + track*30
        addal   %d3,%a1                | + slot2
        addal   #SHADOW1,%a1
        moveb   %d2,%a1@               | shadow <- value (0x4003acba)
        | the four dirty flags, exactly as the editor (0x4003acbe..0x4003acec)
        moveq   #0,%d1
        moveb   PARTB,%d1
        moveq   #1,%d3
        lsll    %d1,%d3                | d3 = 1 << part
        moveal  DBPTR,%a0              | a0 = DB
        moveal  %a0,%a1
        addal   #CHGBITS,%a1
        moveb   %a1@,%d1
        orl     %d3,%d1
        moveb   %d1,%a1@               | DB+0x95048 |= 1<<part
        moveb   MODBITS,%d1
        orl     %d3,%d1
        moveb   %d1,MODBITS            | 0x100b145e |= 1<<part
        addal   #CHGFLAG,%a0
        moveq   #1,%d1
        movel   %d1,%a0@               | DB+0x9b332 = 1
        movel   %d1,GCHG               | 0x100f8598 = 1
        | live = LIVEB + track*72 + 0x32 + slot2 (0x4003ad02..0x4003ad08)
        movel   %d6,%d1
        moveq   #72,%d3
        mulu.l  %d3,%d1                | d1 = track*72
        movel   %d4,%d3
        subql   #6,%d3                 | d3 = slot2
        lea     LIVEB,%a0
        addal   %d1,%a0
        addal   #LANE1,%a0
        addal   %d3,%a0
        moveb   %d2,%a0@
w1skip: rts

| ---- per-engine page-2 value counts, slot2 order (slots 6..11) -----------
| Must match the engines' manifests (busverb / busdelay page-2 counts);
| tools/verify/verify_ccpage2.py checks them against VERB_COUNTS / DLY_COUNTS.
VCOUNT: .byte   3, 128, 128, 4, 128, 4    | MODE SHMR DIFF SHFT GATE RATE
DCOUNT: .byte   3, 128, 128, 4, 128, 2    | MODE MDEP MRAT SIZE PTCH FRZE
