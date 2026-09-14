"""ok-ms -- Octakit + MIDI SCENES on the stock effects.

No octabam DSP, no CC PAGE 2, no LO-FI fix. The 14 stock effects are listed
so the FX2 chooser is stock's (a remix with no FX2 modules otherwise draws
a one-row chooser). Built 14 Sep 2026 as OKMS1 (VERSION=OKMS1); confirmed
working on hardware by midisc's author the same day: the first image from
this pipeline to run on a unit.

Octakit migrates Parts into Kits on load: back up projects first.
"""

from remix.schema import Remix

REMIX = Remix(
    name="ok-ms",
    doc="Octakit + MIDI SCENES on the stock effects: the two mods alone.",
    modules=("MIDI SCENES", "OCTAKIT",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
