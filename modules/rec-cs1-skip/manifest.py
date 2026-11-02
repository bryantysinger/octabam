"""REC CS1 SKIP -- the recorder control-record update (stock 0x4000432c, called
from the write path about 1.5 times a recording track a frame) skips two of
its six writes to CS1 when CS1 already holds the value: [r+300] and [r+308],
which it reads anyway. The memory ends as stock leaves it (skip.s has the
routine and the argument). An experiment in the frame's cost: CS1 costs
about 0.5 us an access on the unit (PC SAMPLER, 1 Nov 2026), and the routine
was 6.4 us a frame per recording track at SELF x4..x7.
"""
from remix.schema import Category, Detour, Kind, Linked, Module, Proof

H = bytes.fromhex
U = "rec_cs1_skip"

MODULE = Module(
    name="rec-cs1-skip",
    key="REC CS1 SKIP",
    kind=Kind.CF_PATCH,
    category=Category.REFERENCE, author="bryantysinger", author_url="https://github.com/bryantysinger",
    proof=Proof.PORT, proof_note="under the port (1 Nov 2026), _bt_pcs_cs1 against _bt_pcs_base, STRESS_INT A07, 8,000 frames: the CS1 records, the arena and the 44-byte records byte-identical at the end; CS1 writes 468,662 -> 317,028; not yet on a unit",
    doc="Experiment: skip two redundant CS1 writes in the recorder's per-frame control-record update.",
    linked=(Linked(U, "modules/rec-cs1-skip/skip.s", cpu="5475", dram=True),),
    detours=(
        Detour(0x4000432c, H("2f032f02222f000c"), U, "rcs_update",
               "the recorder control-record update: the whole routine, two CS1 writes skipped when unchanged",
               pad_to=8),
    ),
)
