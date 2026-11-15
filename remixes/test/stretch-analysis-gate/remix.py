"""stock effects with STRETCH ANALYSIS GATE: the sample-analysis task skips voices whose TSTR is off."""

from remix.schema import Proof, Remix

REMIX = Remix(
    name="stretch-analysis-gate",
    family="mods", proof=Proof.CHECK, proof_note="",
    doc="stock effects with STRETCH ANALYSIS GATE: the sample-analysis task skips voices whose TSTR is off.",
    modules=("STRETCH ANALYSIS GATE",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER",
             "CHORUS", "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI",
             "DELAY", "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
