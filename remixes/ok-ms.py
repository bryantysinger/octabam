"""OK-MS -- Octakit + MIDI SCENES, nothing else of anyone's.

The two community mods that share nothing any more (since his 1.40MIDISC8
leaves apply_part stock, Octakit owns that site alone) on top of the stock
effects, so the FX2 chooser is the stock one. No octabam DSP, no CC PAGE 2,
no bridge (nothing to bridge), no LO-FI fix -- the smallest image that
asks the question "do these two run together on a unit". Built 14 Sep 2026
as OKMS1 (`VERSION=OKMS1`, its own tag outside the OCTABAM numbering; sha256
96a2edd9ee64eac9...) and ✅ CONFIRMED WORKING the same day by midisc's author on
his own unit -- the first image from this pipeline on hardware.
⚠️ Octakit migrates Parts into Kits on load: back up projects first.
"""

from remix.schema import Remix

REMIX = Remix(
    name="ok-ms",
    doc="Octakit + MIDI SCENES on the stock effects: the two mods alone.",
    modules=("MIDI SCENES", "OCTAKIT",
             # the stock chooser, in stock order -- no words, no placement (stock.py)
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
