"""REC CS1 SKIP -- the recorder control-record update (stock 0x4000432c, called
from the write path about 1.5 times a recording track a frame) skips its
writes to CS1 when CS1 already holds the value: [r+300] and [r+308] against
what it reads anyway, and [r+276], [r+280], [r+296].b and [r+304] against a
copy in DRAM that one CS1 read a call, in turn, keeps honest (a foreign
write is caught within four calls). skip.s has the routine and the argument. An experiment in the frame's cost: CS1 costs
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
    proof=Proof.PORT, proof_note="under the port, _bt_pcs_cs1 against _bt_pcs_base on STRESS_INT: A07 for 8,000 frames and a 24,000-frame run through pattern changes, a stop and a start, all of CS1 (1 MB) and the 44-byte records byte-identical at the end; CS1 writes in A07 468,662 (stock) -> 317,028 (option 1) -> 13,855 (2 Nov 2026); option 1 on Bryan T's MKII: the routine 48.0 -> 36.4 us a frame at SELF x7 (1-2 Nov 2026)",
    doc="Experiment: skip the redundant CS1 writes in the recorder's per-frame control-record update.",
    linked=(Linked(U, "modules/rec-cs1-skip/skip.s", cpu="5475", dram=True),),
    detours=(
        Detour(0x4000432c, H("2f032f02222f000c"), U, "rcs_update",
               "the recorder control-record update: the whole routine, two CS1 writes skipped when unchanged",
               pad_to=8),
    ),
)
