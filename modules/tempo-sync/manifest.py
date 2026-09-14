"""TEMPO SYNC -- two ColdFire caves: the DSP learns the tempo, and BusDelay's
TIME draws as a division.

The DSP is never told the tempo (the ColdFire computes every tempo-derived
rate itself). The publish cave hooks the per-frame voice-record writer at
the instruction that stores the FX2 id, replays it, and also stores tempo24,
samples-per-MIDI-clock (Q12.4), the crossfader position and any held MIDI
note into four halfwords of the record that are written every frame and
never read; the DSP reads them at r6+$6..$9.

The cave filters on FX2 ids 6 and 7, compiled into the pinned bytes
(`subq.l #6,%d0; cmpi.l #1,%d0` in tempo_cave.s): a module that changes its
fx2 id must re-assemble and re-pin this cave, or the DSP never sees a tempo.

The formatter cave is BusDelay TIME's display: it prints the division name
("1/8") while the DSP's sticky snap holds one and milliseconds otherwise,
from the same integers as the DSP rule. Position-independent; its two state
longs live inside the cave.

Both caves float in the stock zero run past the descriptor clones.
NOTEMPO=1 installs neither; the DSP then reads zeros and SYNC is a no-op.
"""

from remix.schema import CavePatch, FormatterReg, Kind, Module

# The per-frame voice-record writer, at the instruction that publishes the
# FX2 id. Ten bytes: three instructions, displaced into the cave.
TEMPO_HOOK = 0x40004d40
TEMPO_HOOK_STOCK = bytes.fromhex("14280dbc" "4882" "35420038")

TEMPO_CAVE_BYTES = bytes.fromhex(
    "14280dbc" "4882" "35420038"           # displaced: id -> +0x38
    "2f00" "2002" "5d80" "0c8000000001" "624c"   # id-6 > 1 -> skip
    "2f01"
    "2039460d16c8" "5280" "35400028"       # fader+1 -> +0x28 (r6+$8)
    "2f08" "41f9400d64c2" "10304800" "205f"  # held note[d4] ...
    "0280000000ff" "0c80000000ff" "6602" "4280"  # 0xff (released) -> 0
    "3540002a"                             # ... -> +0x2a (r6+$9)
    "20398000181c" "6712"                  # tempo24; 0 -> nodiv (divu.l by 0
                                           # hangs the boot)
    "35400024"                             # tempo24 -> +0x24 (r6+$6)
    "223c0285ff00" "4c401001" "35410026"   # 42336000/tempo24 -> +0x26
    "221f" "201f" "4e75")

TIME_FMT_BYTES = bytes.fromhex("4fefffec48d7043c202f001c45fa010a2200ef89068100000040b0926748248042aa0004243980001814673a263c0285ff004c4230032401e88a41fa008878007a001a184c035000e88d9a816a024485ba8264082544000452aa000452840c840000000a66da202a0004672241fa006032300afe02810000ffffd1c12f48001c4cd7043c4fef00144ef940013a08700a4c001000203c000001b94c4010012f41001c4cd7043c4fef00142f2f00084879400b465d2f2f000c4eb940013a084fef000c4e750203040608090c1012180014001a001f0025002a002f00350039003e0043312f33325400312f333200312f31365400312f313600312f385400312f31362e00312f3800312f345400312f382e00312f3400000000ffffffff00000000")

MODULE = Module(
    name="tempo-sync",
    key="TEMPO SYNC",
    kind=Kind.CF_PATCH,
    doc="ColdFire caves: publishes tempo/fader/note to the DSP, and draws "
        "BusDelay TIME as a tempo division.",
    cf_patches=(
        CavePatch(
            label="tempo cave",
            cave_addr=None,          # floats: 0x400d7000 behind three clones
            pinned=TEMPO_CAVE_BYTES,
            source="modules/tempo-sync/tempo_cave.s",
            hook_addr=TEMPO_HOOK,
            hook_stock=TEMPO_HOOK_STOCK,
            report_note=" (tempo24 -> r6+$6, clocks Q12.4 -> r6+$7, "
                        "fader+1 -> r6+$8, note -> r6+$9; ids 6/7)",
        ),
        CavePatch(
            label="time_fmt cave",
            cave_addr=None,          # floats: 0x400d7080 behind the tempo cave
            pinned=TIME_FMT_BYTES,
            source="modules/tempo-sync/time_fmt.s",
            # A (P+0x0ca) points at the cave and B (P+0x0fa) stays zero --
            # stock DELAY TIME's own configuration.
            registers_formatter=FormatterReg(module="DELAY SERVER", slot=0),
            report_note=", registered as BusDelay TIME's formatter",
        ),
    ),
)
