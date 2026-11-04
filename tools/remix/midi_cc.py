"""MIDI CC numbers no module may send or map (issue #981).

These CCs hold state on the receiving synth, or reconfigure it, until
another message undoes them. A module that maps one also hears it from any
controller that sends it unasked (a sustain pedal on a keyboard), and a
module that transmits one, as CC FEEDBACK does at every project load, sets
it on every synth listening on that channel. CC MAP used 62-73 until
1 Nov 2026: its FX2 page-2 block held CC 64, and a load sent a held sustain
to every synth on channels 1-8, so their notes kept sounding.

Any other CC may still be one of a synth's own parameters. Keeping the
Octatrack's track channels away from external synths is the musician's
job; this list only keeps out the CCs whose effect lasts.
"""

STATEFUL = {
    0: "bank select MSB", 32: "bank select LSB",
    6: "data entry MSB", 38: "data entry LSB",
    64: "sustain", 65: "portamento on/off", 66: "sostenuto", 67: "soft pedal",
    68: "legato footswitch", 69: "hold 2",
    96: "data increment", 97: "data decrement",
    98: "NRPN LSB", 99: "NRPN MSB", 100: "RPN LSB", 101: "RPN MSB",
    120: "all sound off", 121: "reset all controllers", 122: "local control",
    123: "all notes off", 124: "omni off", 125: "omni on", 126: "mono on", 127: "poly on",
}

# Stock's own audio-track CCs (docs/firmware/MIDI.md section 1) that are in
# STATEFUL: the page-1 knobs CC 32 (LFO page 1, the fifth slot) and CC 38
# (FX1 page 1, the fifth). Stock sends them on a panel turn, and CC FEEDBACK
# sends them at every project load as the rest of page 1. Not a module's
# choice; recorded so the overlap is known (issue #981).
STOCK_STATEFUL = {32: "LFO page 1 slot 4", 38: "FX1 page 1 slot 4"}


def refuse_stateful(owner: str, ccs) -> tuple:
    """`ccs` as a tuple, or ValueError naming each stateful CC `owner` claims."""
    ccs = tuple(ccs)
    bad = [f"CC {c} ({STATEFUL[c]})" for c in ccs if c in STATEFUL]
    if bad:
        raise ValueError(f"{owner}: {', '.join(bad)} hold state on the receiving synth "
                         f"(tools/remix/midi_cc.py); choose CC numbers outside STATEFUL")
    if any(not 0 <= c <= 127 for c in ccs) or len(set(ccs)) != len(ccs):
        raise ValueError(f"{owner}: CC numbers must be distinct and 0..127, got {ccs}")
    return ccs


def ccmap_ccs() -> tuple[tuple, tuple]:
    """CC MAP's page-2 numbers, (FX2_CCS, FX1_CCS), slots 6..11 in order:
    what CC MAP reads and CC FEEDBACK sends. Tools and gates take them from
    here rather than spelling the numbers."""
    import importlib.util
    import pathlib
    path = pathlib.Path(__file__).resolve().parents[2] / "modules/cc-map/manifest.py"
    spec = importlib.util.spec_from_file_location("ccmap_manifest", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.FX2_CCS, m.FX1_CCS


def ccmap_cc(fx: str, slot: int) -> int:
    """CC MAP's CC for page-2 `slot` (6..11) of `fx` ('FX1' or 'FX2')."""
    fx2, fx1 = ccmap_ccs()
    if not 6 <= slot <= 11:
        raise ValueError(f"CC MAP covers page-2 slots 6..11, not {slot}")
    return {"FX2": fx2, "FX1": fx1}[fx.upper()][slot - 6]
