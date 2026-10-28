"""STRETCH ANALYSIS GATE -- the sample analyzer skips voices that do not time-stretch.

Stock runs a sample-analysis task (0x40098a5c, priority 1, BRAIN's CPU row
TASK 98A5C) over every playing FLEX, STATIC and PICKUP voice: per voice it
refreshes an entry in the table 0x80006924 (0x4009871c) and analyses the
sample in 512-unit chunks (0x400985ac: unpack to SRAM, biquad, rectify,
decimate, envelope, onsets), looping without sleeping while any voice is
pending. Its only readers are the voice renderer's time-stretch splice
branches, 0x40008250 (forward) and 0x40008a1a (reverse), inside the
renderer's TSTR-on paths (docs/firmware/REPITCH.md: the resolved TSTR is
voice +24). A voice whose resolved TSTR is off never reads it.

One ROM cave, one detour at 0x40098b2c, the task's table check right after
it copies the voice record to 44(sp): the copy's +24 (68(sp)) zero -> the
task's own next-voice path (0x40098cc8, where stock goes for a voice it does
not analyse); non-zero -> the displaced `movea.l (a3),a0; cmpa.l 188(sp),a0;
beq.s` replayed. A TSTR-on voice runs stock code unchanged; a skipped voice
keeps its table entry and analysis state, as stock leaves them for any
voice it skips, and the renderer's own key match decides whether an entry
applies once its TSTR is on.

Why: with recorder buffers looping at the project tempo and TSTR off, the
task's work is never used, yet BRAIN shows it at 30-73% of the ColdFire
with five to seven loops (Bryan T's MKII, OCTABAM24, 24 Oct 2026), at the
priority the engine and the UI event loop share.

Under the port, 24 Oct 2026 (README): with TSTR resolved off, five and
seven 16-step SOS loops take 850-920 chunk calls a track over 20 s in stock
and none with the module, and record byte for byte the same; with it
resolved on (2), five and seven 64-step loops take the same calls as stock
and record the same. What it frees on a unit is not measured yet.
"""

from remix.schema import Category, Detour, Kind, Linked, Module, Proof

GATE_SITE = 0x40098B2C
GATE_STOCK = bytes.fromhex("2053" "b1ef00bc" "672a")   # movea.l (a3),a0; cmpa.l 188(sp),a0; beq.s 0x40098b5e

MODULE = Module(
    name="stretch-analysis-gate",
    key="STRETCH ANALYSIS GATE",
    kind=Kind.CF_PATCH,
    category=Category.FIXES, author="bryantysinger", author_url="https://github.com/bryantysinger",
    proof=Proof.PORT,
    proof_note="under the port, 24 Oct 2026: TSTR-off voices take no chunk calls (stock 850-920 a track over 20 s), "
               "five and seven SOS loops record byte for byte the same; TSTR-on voices take stock's calls",
    doc="The stock sample-analysis task (TASK 98A5C) skips voices whose resolved TSTR is off: "
        "its only reader is the time-stretch splice, so that work was never used.",
    linked=(Linked("sag", "modules/stretch-analysis-gate/gate.s"),),
    detours=(
        Detour(GATE_SITE, GATE_STOCK, "sag", "sag_gate",
               "sample-analysis task, per voice: TSTR off -> next voice", kind="jmp", pad_to=8),
    ),
)
