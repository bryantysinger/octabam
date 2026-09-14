# Tempo sync

Two ColdFire code caves.

**The publish cave** hooks the per-frame voice-record writer, replays the
instruction it displaced, and stores the project tempo, samples-per-MIDI-clock,
the crossfader position and any held MIDI note into four halfwords of the
record that are written every frame and never read. They arrive on the DSP
side as `r6+$6..$9`.

**The formatter cave** draws BusDelay's TIME knob: the division name while
the DSP's sticky snap holds one, milliseconds otherwise.

`NOTEMPO=1` installs neither (the DSP reads zeros, SYNC is a no-op).
`TEMPOCAVE=replay` installs a cave that only replays the displaced
instructions, isolating the hook mechanism from the stores.

On the unit since 24 Aug 2026.

## Open

The publish cave filters on FX2 ids 6 and 7, compiled into the pinned bytes.
A module that changes its id must re-assemble and re-pin this cave.

Background: [`docs/firmware/DSP.md`](../../docs/firmware/DSP.md) §6c,
[`docs/firmware/PARAM_PAGES.md`](../../docs/firmware/PARAM_PAGES.md) §7.
