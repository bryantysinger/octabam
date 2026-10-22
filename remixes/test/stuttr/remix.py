"""STUTTR beside stock FX (PLATE REV harvested for its words)."""

from remix.schema import Proof, Remix

REMIX = Remix(
    name="stuttr",
    family="effects",
    proof=Proof.RENDER,
    proof_note="verify_stuttr; chance-engage redesign.",
    doc="STUTTR beside the stock effects (all but PLATE REV, whose words it takes).",
    modules=(
        "STUTTR",
        "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER",
        "CHORUS", "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI",
        "DELAY", "SPRING REV", "DARK REV",
    ),
    fallback="NONE",
)
