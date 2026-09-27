"""usb-mc -- stock effects plus USB MIDI and USB AUDIO MC, nothing else.

usb-lean with MAIN L/R + CUE L/R only, at the 250 us cadence (not
USB AUDIO MASTER's 1 ms). For testing USB AUDIO MC on a unit that runs
stock projects. Local test remix (27 Sep 2026).
"""

from remix.schema import Proof, Remix

REMIX = Remix(
    name="usb-mc",
    family="mods", proof=Proof.PORT, proof_note="",
    doc="stock + USB MIDI + USB AUDIO MC (4 ch: MAIN + CUE).",
    modules=("USB MIDI", "USB AUDIO MC",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
