"""bamsep26 -- the rig: the bus, three stations, the stock delay.

FX2 rows: BusVerb (runs on T5 only), BusDelay (T1 only), SEND (the
fallback: one AUX knob); an engine chosen on any other track is a dry pass
(22 Sep 2026; until then BusVerb ran on any of T5-8, BusDelay on T1-4, and
the stock DELAY had a row). FX1 rows: NONE + the three stations, each on the id of the stock
effect it replaces (Spectrum = FILTER 0x04, Character = LO-FI 0x1c,
Modulation = CHORUS 0x12) and FX1-only; a station named on FX2 runs dry.
Each station defaults to a bit-exact passthrough, so a saved part that
chose the stock effect still plays.

The bus is one aux: SEND -> BusDelay -> BusVerb, each engine's wet printed
on the track that hosts it (20 Sep 2026; until then a return on T8 through
Character). TEMPO SYNC makes BusDelay's TIME read divisions; CC
PAGE 2 puts CC 62-67 on the host engine's page-2 slots; MODE DEFAULTS
re-defaults a mode's knobs when MODE is turned on the panel.

Every other stock effect is harvested: 13 effects, 6,158 words per payload
in one run; a saved part naming one gets silence (the null stub).

On Sam's unit. Worst core priced 3,657 cycles (four Characters beside the
reverb, `make cycles`, 20 Sep 2026) against 3,120 usable -- inside the
counter's error margin, settled by the hardware burn sweep.
"""

from remix.schema import Remix

REMIX = Remix(
    name="bamsep26",
    doc="The rig: bus (BusVerb on T5 + BusDelay on T1) + three stations.",
    modules=("REVERB SERVER", "DELAY SERVER", "SEND",
             "SPECTRUM", "CHARACTER", "MODULATION",
             "TEMPO SYNC", "CC PAGE 2", "MODE DEFAULTS"),
    fallback="SEND",
    # 22 Sep 2026: the engines run on their host slots only (BusDelay on T1,
    # BusVerb on T5) and are a dry pass anywhere else; the stock DELAY row
    # is out of the chooser. Every other FX2 is a SEND.
    locked=("REVERB SERVER", "DELAY SERVER"),
    fx1=("SPECTRUM", "CHARACTER", "MODULATION"),
)
