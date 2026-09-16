"""REPITCH -- tempo-following variable-speed playback as TSTR raw value 4."""

from remix.schema import Detour, Kind, Linked, Module, Poke, SymbolRef

H = bytes.fromhex

MODULE = Module(
    name="repitch",
    key="REPITCH",
    kind=Kind.CF_PATCH,
    doc="Adds TSTR REPITCH: project-tempo following by playback speed, without grains.",
    linked=(Linked("repitch", "modules/repitch/repitch.s"),),
    detours=(
        Detour(0x40004100, H("a1c0eca027400024"), "repitch", "rate_hook",
               "scale the shared CPU/DSP playback increment", pad_to=8),
        Detour(0x40007EDE, H("4a2a0018661e42aa0080"), "repitch", "grain_gate",
               "raw 4 takes the dry renderer path", pad_to=10),
        Detour(0x40008210, H("4a2a001866082a6effcc"), "repitch", "tempo_gate",
               "raw 4 uses dry tempo/reciprocal state", pad_to=10),
    ),
    symbol_refs=(
        SymbolRef(0x400D310E, 0x4003B6A4, "repitch", "tstr_fmt",
                  "STATIC TSTR formatter"),
        SymbolRef(0x400D32A0, 0x4003B6A4, "repitch", "tstr_fmt",
                  "FLEX TSTR formatter"),
        SymbolRef(0x400D3756, 0x4003B6A4, "repitch", "tstr_fmt",
                  "PICKUP TSTR formatter"),
    ),
    pokes=(
        Poke(0x400D30DE, H("00000004"), H("00000005"),
             "STATIC TSTR count 4 -> 5"),
        Poke(0x400D3270, H("00000004"), H("00000005"),
             "FLEX TSTR count 4 -> 5"),
        Poke(0x400D3726, H("00000003"), H("00000004"),
             "PICKUP TSTR count 3 -> 4 (minimum remains 1)"),
    ),
)
