| rec-uncached.s -- REC UNCACHED: the recorder's pack loops write through the
| uncached SDRAM alias.
|
| The pack routine 0x40007826 walks a table of {destination, count} segments
| at 76(sp) and writes each segment's frames with one of four loops (24/16
| bit, forward/backward), every one addressing through d1 = the segment's
| destination. The recorder blocks are in SDRAM at 0x40000000-0x47ffffff,
| which ACR0 (0x4007e020) makes cacheable copyback: a store that misses
| allocates the line, so the CPU waits on a 16-byte fill per line it writes,
| and the dirty lines displace the frame interrupt's data. Through the alias
| (+0x08000000, cache-inhibited, PLACEMENT.md) the stores go out without a
| fill. The voice that plays the buffer reads it by eDMA, from SDRAM, either
| way.
|
| TEST IMAGE: a line of a recorder block already in the data cache (the
| sample analyzer reads the buffers with the CPU) is not updated by a write
| through the alias, so a cached reader can see the old audio there until
| the line leaves the cache. The recording and its playback are not
| affected; a cached read of a buffer (the analyzer, SAMPLE SAVE of a
| recording) may be. Do not save recordings from this image.
|
| The jsr replaces `moveal %sp@(76),%a0 / movel %a0@,%d1` (6 bytes); the
| return address moves the table pointer to 80(sp). The flags are reset by
| the displaced code's next instruction (movel %a0@(4),%d0).
| SPDX-License-Identifier: MIT

.set UNCACHED, 0x08000000

    .text
    .global ru_seg
ru_seg:
    moveal  %sp@(80),%a0            | the segment entry
    movel   %a0@,%d1                | its destination
    cmpil   #0x40000000,%d1
    bcss    1f
    cmpil   #0x48000000,%d1
    bccs    1f                      | not the cached SDRAM: left alone
    oril    #UNCACHED,%d1
1:  rts
