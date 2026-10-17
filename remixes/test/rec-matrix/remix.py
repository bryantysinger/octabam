"""REC MATRIX on the stock effects, with BRAIN storing each recorder's matrix in the project."""
from remix.schema import Proof, Remix

REMIX = Remix(
    name="rec-matrix", family="mods", proof=Proof.CHECK,
    proof_note="the matrix as BRAIN PROJECT settings REC1..REC8",
    doc="Stock effects with recorder SRC3 = MTRX recording a per-recorder sum of sources, kept in the project by BRAIN.",
    modules=("BRAIN", "REMIX SWITCH", "REC MATRIX", "FILTER", "EQUALIZER", "DJ EQ", "PHASER",
             "FLANGER", "CHORUS", "SPATIALIZER", "COMB FILTER", "COMPRESSOR",
             "LO-FI", "DELAY", "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
