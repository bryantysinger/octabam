"""recfix -- the recorder loop click fix, and nothing else.

Three ColdFire caves, no DSP code of ours, the 14 stock effects listed so
the chooser is stock's:

  FLEX SEEK BIND      a same-buffer re-bind is a SEEK for the DSP, not a new
                      note (removes the voice-restart transient)
  FLEX SEEK BIND CTR  the per-bind counter is held (removes the +/-1.5-sample
                      seam)
  RECORDER SPACING    each fixed-RLEN pass is exactly as long as the gap to
                      its next arm (removes the skipped sample on alternate
                      bars at tempos whose length is not an integer)

docs/firmware/RECORDER_CLICK.md has the reproduction. Measured on hardware
as OCTABAM83 (these caves plus the bus); this remix without the bus is
port-gated only. Whether RECORDER SPACING alone would suffice is untested.
"""

from remix.schema import Remix

REMIX = Remix(
    name="recfix",
    doc="The recorder loop click: the three ColdFire fixes beside the stock FX2 "
        "chooser, no DSP code of our own.",
    modules=("FLEX SEEK BIND", "FLEX SEEK BIND CTR", "RECORDER SPACING",
             "FILTER", "EQUALIZER", "DJ EQ", "PHASER", "FLANGER", "CHORUS",
             "SPATIALIZER", "COMB FILTER", "COMPRESSOR", "LO-FI", "DELAY",
             "PLATE REV", "SPRING REV", "DARK REV"),
    fallback="NONE",
)
