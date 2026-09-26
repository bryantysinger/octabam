"""usb-io -- the Octatrack as a USB interface: 20 channels in (tracks 1-16,
MAIN 17-18, CUE 19-20) and 4 channels out to inputs A-D, plus USB MIDI.

Stock effects minus SPATIALIZER, whose words on payload A hold the DSP
inject (modules/usbaudio-out). Inputs A-D carry the host's channels 1-4
while its output stream is open, the jacks otherwise (Bryan T, 26 Sep 2026).
"""

from remix.schema import Remix

REMIX = Remix(
    name="usb-io",
    doc="stock - SPATIALIZER + USB MIDI + USB AUDIO (20 in) + USB AUDIO OUT (4 out -> inputs A-D).",
    modules=("USB MIDI", "USB AUDIO", "USB AUDIO OUT",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fx1=("FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
         "COMB FILTER", "COMPRESSOR", "LO-FI"),
    fallback="NONE",
)
