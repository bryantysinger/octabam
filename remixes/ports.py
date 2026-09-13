"""PORTS -- two of the JSFXClones ports (Inflator, TapeHead) beside
SEND, to gate them in this toolchain for the first time (13 Sep 2026). Not a
rig: a measurement of words, cycles and every gate."""
from remix.schema import Remix

REMIX = Remix(
    name="ports",
    doc="Two JSFX ports (Inflator, TapeHead) gated beside SEND in the stock donor region.",
    modules=("SEND", "INFLATOR", "TAPEHEAD"),   # Phoenix (1,965 words) needs the full donor run; priced separately (995 cycles/sample)
    fallback="SEND",
)
