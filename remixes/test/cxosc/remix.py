"""cxosc -- CX OSC complex-oscillator machine on the stock effects.

Milestone 1 gate: the local CX OSC module alone (conflicts with SYNTH
MACHINE). Stock FX chooser.
"""

from remix.schema import Proof, Remix

REMIX = Remix(
    name="cxosc",
    family="mods", proof=Proof.CHECK,
    proof_note="port check: marker-less machine list, FOLD/SYMM/FDBK in the voice",
    doc="CX OSC (machine list, no marker): PTCH RATO INDX FOLD SYMM FDBK on the stock effects.",
    modules=("CX OSC",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
