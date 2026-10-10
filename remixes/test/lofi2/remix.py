"""LOFI2 beside 13 stock effects: PLATE REV gives up its words for LOFI2's code."""
from remix.schema import Proof, Remix
REMIX = Remix(family="effects", proof=Proof.CHECK, proof_note="make check REMIX=lofi2",
              name="lofi2", doc="LOFI2 beside the stock effects (all but PLATE REV, whose words it takes).",
              modules=("LOFI2",
                       "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER",
                       "CHORUS", "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI",
                       "DELAY", "SPRING REV", "DARK REV"),
              fallback="NONE")
