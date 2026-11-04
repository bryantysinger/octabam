"""SHATTER beside stock FX (PLATE REV harvested for its words)."""

from remix.schema import Proof, Remix

REMIX = Remix(
    name="shatter",
    family="effects",
    proof=Proof.HARDWARE,
    proof_note="Ilia's MKII, BUILD S6 (SHATTER S6.RMX), 21 Oct 2026: every "
               "SHATTER knob exercised; verify_shatter. Solo gate remix.",
    doc="SHATTER beside the stock effects (all but PLATE REV, whose words it takes).",
    modules=(
        "SHATTER",
        "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER",
        "CHORUS", "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI",
        "DELAY", "SPRING REV", "DARK REV",
    ),
    fallback="NONE",
)
