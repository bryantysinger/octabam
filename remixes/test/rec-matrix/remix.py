"""REC MATRIX proof of concept on the stock effects."""
from remix.schema import Proof, Remix

REMIX = Remix(
    name="rec-matrix", family="mods", proof=Proof.CHECK,
    proof_note="proof of concept; the fixed matrix records recorder 2 = A + B + T1",
    doc="Stock effects with recorder SRC3 = MTRX (10) recording a per-recorder sum of sources.",
    modules=("REC MATRIX", "FILTER", "EQUALIZER", "DJ EQ", "PHASER",
             "FLANGER", "CHORUS", "SPATIALIZER", "COMB FILTER", "COMPRESSOR",
             "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
