"""mods -- every community firmware mod in one image, stock effects only.

MIDI SCENES (bkkbrls-del), Octakit (Em), the LO-FI AMF fix (Bryan T) and
CC PAGE 2 (octabam); SCENES KITS bridges CC PAGE 2 and Octakit at the CC
dispatch entry. No octabam DSP; the 14 stock effects are listed so the FX2
chooser is stock's. Booted under the ColdFire port; unflashed as a whole
(ok-ms, its subset, has run on hardware).

Octakit migrates Parts into Kits on load: back up projects first. His Part
save/reload menu hooks against her Kit menus are unmeasured.
"""

from remix.schema import Remix

REMIX = Remix(
    name="mods",
    doc="Every community firmware mod in one image: MIDI SCENES + Octakit + "
        "the LO-FI AMF fix + CC to page 2, bridged.",
    modules=("MIDI SCENES", "OCTAKIT", "LOFI AMF FIX", "CC PAGE 2", "SCENES KITS",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
