"""REC MATRIX (proof of concept): a recorder SRC3 value MTRX (10) that records a
sum of sources chosen per recorder, through stock's SRC3 slot.

One detour at the recorder's SRC3 select (0x400075de, inside the write path
0x400068e4): stock's `mvsb d1,d1; moveq #7,d4; cmpl d1,d4` becomes a jmp to
rmx_select, which replays them for every value but 10. For 10 it sums the
recorder's sources for the current segment into its own block and hands
stock that block as the SRC3 pointer (d5) at 0x40007648, so stock's SRC3
gain and fades, INAB/INCD, the old-content path, the saturating sum and the
pack all run unchanged. Mixing rules follow stock's INAB table (README.md).

Proof of concept: the matrix is a constant (recorder 2 = A + B + T1), set by
writing SRC3 = 10 into a fixture's Part; no page label, no storage, no UI.
"""
from remix.schema import Category, Detour, Kind, Linked, Module, Proof

SELECT_SITE = 0x400075DE
SELECT_STOCK = bytes.fromhex("7301" "7807" "b881")   # mvsb d1,d1; moveq #7,d4; cmpl d1,d4

MODULE = Module(
    name="rec-matrix", key="REC MATRIX", kind=Kind.CF_PATCH,
    category=Category.UTILITIES, author="bryantysinger", author_url="https://github.com/bryantysinger",
    proof=Proof.CHECK,
    proof_note="proof of concept; not yet run",
    doc="Recorder SRC3 = MTRX (10): records a per-recorder sum of inputs, tracks, MAIN and CUE.",
    linked=(Linked("rmx", "modules/rec-matrix/rmx.s", dram=True),),
    detours=(Detour(SELECT_SITE, SELECT_STOCK, "rmx", "rmx_select",
                    "SRC3 select: 10 (MTRX) points the SRC3 source at the recorder's summed block",
                    kind="jmp"),),
)
