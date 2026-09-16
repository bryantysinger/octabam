# Repitch

Adds raw value 4, `REPITCH`, to the existing TSTR selector. Existing values
remain byte-compatible: OFF=0, AUTO=1, NORM=2, BEAT=3.

REPITCH routes playback through the stock dry interpolator and scales the
single playback increment shared by ColdFire source consumption and the DSP
voice command:

`increment *= project_bpm24 / sample_bpm24`

The source BPM comes from the bound sample settings at `+0x114`. A missing or
zero source/project tempo leaves the stock increment unchanged. The integer
calculation uses quotient and remainder so the multiplication does not lose
the fractional tempo ratio.

Status: emulator/build validation in progress; not hardware-tested. Initial
scope is correctly attributed loops at neutral PTCH/RATE. Reverse, slices,
live tempo changes, extreme pitch/rate modulation, Pickup and Static streaming
still require dedicated playback tests before recommending a flash.
