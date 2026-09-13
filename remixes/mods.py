"""MODS -- every community firmware mod in one image, stock effects only.

MIDI SCENES (bkkbrls-del), Octakit (Em), the LO-FI AMF fix (Bryan T) and
CC to page 2 (octabam), bridged by SCENES KITS at the one stock site two
of them still share (the CC dispatch: our cave, then hers, then stock's;
apply_part is Octakit's alone since his 1.40MSCN6). Nothing of octabam's
DSP is placed; the 14 stock effects are listed so the FX2 chooser is the
stock one. ⚠️ Octakit migrates Parts into Kits
on load: back up projects first. ⚠️ The apply path is measured under the
port; his Part save/reload menu hooks against her Kit menus are not (see
modules/scenes-kits). Unflashed.
"""

from remix.schema import Remix

REMIX = Remix(
    name="mods",
    doc="Every community firmware mod in one image: MIDI SCENES + Octakit + "
        "the LO-FI AMF fix + CC to page 2, bridged.",
    modules=("MIDI SCENES", "OCTAKIT", "LOFI AMF FIX", "CC PAGE 2", "SCENES KITS",
             # the stock chooser, in stock order -- no words, no placement
             # (stock.py). Without it a cave-only remix draws an FX2 chooser
             # of ONE row (the recfix trap, 12 Sep 2026).
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
