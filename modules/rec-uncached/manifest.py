"""REC UNCACHED -- the recorder's pack loops write the recorder blocks through
the uncached SDRAM alias instead of the cached copyback one (unit.s says why).

A TEST MODULE for the ColdFire budget (docs/firmware/CF_BUDGET.md): whether
the recorder's frame-interrupt cost on hardware is the write-allocate line
fills of a copyback store stream, made worse by a streaming USB IN. Under the
port (no cache model, the alias folded onto the cached address) the recorded
audio must be unchanged; what it frees can only be measured on a unit
(tools/hw/analyzer_sweep.py --only REC, with and without --usb-in).
A cached reader of a recorder buffer (the analyzer, SAMPLE SAVE) can see stale
lines on hardware: not for use beyond that measurement.
"""
from remix.schema import Category, Detour, Kind, Linked, Module, Proof

MODULE = Module(
    name="rec-uncached",
    key="REC UNCACHED",
    kind=Kind.CF_PATCH,
    category=Category.REFERENCE, author="bryantysinger", author_url="https://github.com/bryantysinger",
    proof=Proof.PORT, proof_note="port, 27 Oct 2026: 8 SOS loops recorded and played back the same (one sample later: the transport started one ESAI frame later, residual -90 dB), the pack loops writing 0x4cc..-0x4e0..; no cache model; not run on a unit",
    doc="Test: the recorder writes its blocks through the uncached SDRAM alias (no line fills).",
    linked=(Linked("rec_uncached", "modules/rec-uncached/unit.s", cpu="5475", dram=True),),
    detours=(
        Detour(0x40007826, bytes.fromhex("206f004c" "2210"), "rec_uncached", "ru_seg",
               "the pack routine's segment fetch: the destination, moved to the uncached alias", kind="jsr"),
    ),
)
