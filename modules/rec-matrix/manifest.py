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
from remix.schema import Category, Detour, Kind, Linked, Module, Poke, Proof

H = bytes.fromhex

SELECT_SITE = 0x400075DE
SELECT_STOCK = H("7301" "7807" "b881")              # mvsb d1,d1; moveq #7,d4; cmpl d1,d4

# Stored SRC3: 0 -, 1..8 T1..T8, 9 MAIN, 10 CUE; MTRX is stored as 11.
SRC3_COUNT = 0x400D3C74 + 0xD2 + 4 * 4                # descriptor entry 8, slot 4, u32
VALIDATOR_CMP = 0x40002CB2                             # moveq #10,d1 (SRC3 max)
VALIDATOR_SET = 0x40002CB8                             # moveq #10,d3 (written over a larger value)

MODULE = Module(
    name="rec-matrix", key="REC MATRIX", kind=Kind.CF_PATCH,
    category=Category.UTILITIES, author="bryantysinger", author_url="https://github.com/bryantysinger",
    proof=Proof.PORT,
    proof_note=("under the port, 17 Oct 2026, a 24-bit recording of 19,120 samples (recorder 2 = A + B + T1): "
                "the input half equals 0.5(A+B) at gain 1.0000000 and the T1 half equals the take stock SRC3 = T1 records, "
                "both within 1 LSB; not on hardware"),
    doc="Recorder SRC3 = MTRX (10): records a per-recorder sum of inputs, tracks, MAIN and CUE.",
    linked=(Linked("rmx", "modules/rec-matrix/rmx.s", dram=True),),
    detours=(Detour(SELECT_SITE, SELECT_STOCK, "rmx", "rmx_select",
                    "SRC3 select: 10 (MTRX) points the SRC3 source at the recorder's summed block",
                    kind="jmp"),),
    pokes=(
        Poke(SRC3_COUNT, (11).to_bytes(4, "big"), (12).to_bytes(4, "big"), "SRC3 count 11 -> 12 (MTRX)"),
        Poke(VALIDATOR_CMP, H("720a"), H("720b"), "part validator: SRC3 max 10 -> 11"),
        Poke(VALIDATOR_SET, H("760a"), H("760b"), "part validator: SRC3 max 10 -> 11"),
    ),
)
