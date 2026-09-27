"""usb-io -- the Octatrack as a four-in, four-out USB interface, plus USB MIDI.

USB AUDIO MC (MAIN L/R + CUE L/R to the host) and USB AUDIO IN (four
channels from the host into inputs A-D, the jacks while its stream is
closed): usbin-test's usb-io (Bryan T, 26 Sep 2026) on the current layouts.
Stock effects minus SPATIALIZER, whose words on payload A hold USB AUDIO
IN's DSP inject: listed on neither chooser, so neither menu offers it.
"""

from remix.schema import Proof, Remix

REMIX = Remix(
    name="usb-io",
    family="mods", proof=Proof.PORT, proof_note="",
    doc="stock - SPATIALIZER + USB MIDI + USB AUDIO MC (4 ch: MAIN + CUE) + USB AUDIO IN (4 ch -> inputs A-D).",
    modules=("USB MIDI", "USB AUDIO MC", "USB AUDIO IN",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fx1=("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
         "COMB FILTER", "COMPRESSOR", "LO-FI"),
    fallback="NONE",
)
